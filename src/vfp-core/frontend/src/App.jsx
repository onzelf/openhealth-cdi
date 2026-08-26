import { useEffect, useMemo, useRef, useState } from "react";
import {
  CartesianGrid,
  Legend,
  Line,
  LineChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";

import logoUrl from "../openhealth_logo.avif";
const RUN_ID = import.meta.env.VITE_RUN_ID || "local-pathmnist-ab-001";
const APP_VERSION = "v0.3.2-react-vite";
const POLL_MS = 2500;
const ADMIN_TABS = ["training", "metrics", "clients", "events", "evidence"];
const USER_TABS = ["model-use", "events", "evidence"];
const USER_TISSUES = [
  "adipose",
  "background",
  "debris",
  "lymphocytes",
  "mucus",
  "smooth_muscle",
  "normal_colon_mucosa",
  "cancer_associated_stroma",
  "colorectal_adenocarcinoma_epithelium",
];
const MODE1B_TISSUES = [
  "cancer_associated_stroma",
  "colorectal_adenocarcinoma_epithelium",
];

const SCENARIOS = [
  {
    id: "ab",
    title: "A+B Baseline",
    organisations: "Hospital A + Hospital B",
    actors: "Audrey · Bob",
    detail: "Founding members · train and query",
    participantOrgIds: ["org://HospitalA", "org://HospitalB"],
    expectedRegisteredClients: 2,
    statement:
      "Hospitals A and B train the baseline model under the active sovereignty envelope.",
  },
  {
    id: "mode1a",
    title: "Mode 1A",
    organisations: "Hospital A + Hospital B + sponsored Hospital C",
    actors: "Audrey · Bob · Charlie",
    detail: "Guest contributor · train A+B+C",
    participantOrgIds: [
      "org://HospitalA",
      "org://HospitalB",
      "org://HospitalC",
    ],
    expectedRegisteredClients: 3,
    statement:
      "Hospital C is admitted as a sponsored training contributor; the A+B+C model remains queryable by A and B.",
  },
  {
    id: "mode1b",
    title: "Mode 1B",
    organisations: "Hospital A + Hospital B + AI agent",
    actors: "Audrey · Bob · Hal",
    detail: "Bounded AI task · reuse A+B+C",
    participantOrgIds: ["org://HospitalA", "org://HospitalB"],
    expectedRegisteredClients: 2,
    statement:
      "Hal receives a holder-bound, envelope-bound capability and participates only within its admitted task.",
  },
];

async function getJson(path) {
  const response = await fetch(`/api${path}`, { cache: "no-store" });
  if (!response.ok) {
    throw new Error(`${path} failed: ${response.status}`);
  }
  return response.json();
}

async function postJson(path, payload) {
  const response = await fetch(`/api${path}`, {
    method: "POST",
    headers: payload ? { "Content-Type": "application/json" } : undefined,
    body: payload ? JSON.stringify(payload) : undefined,
  });
  if (!response.ok) {
    let detail = "";
    try {
      const body = await response.json();
      detail = body.detail ? ` · ${body.detail}` : "";
    } catch {
      detail = "";
    }
    throw new Error(`${path} failed: ${response.status}${detail}`);
  }
  return response.json();
}

function formatMetric(rows, key) {
  const values = rows
    .map((row) => row[key])
    .filter((value) => value !== "" && value !== undefined && value !== null);

  if (!values.length) {
    return "—";
  }

  const numeric = Number(values[values.length - 1]);
  return Number.isFinite(numeric) ? numeric.toFixed(4) : values[values.length - 1];
}

function latestRound(rows) {
  const rounds = rows
    .map((row) => Number(row.round))
    .filter((round) => Number.isFinite(round));

  return rounds.length ? Math.max(...rounds) : 0;
}

function compactIdentifier(value) {
  if (!value) {
    return "Not bound";
  }
  return value.length > 18
    ? `${value.slice(0, 8)}…${value.slice(-4)}`
    : value;
}

function toMetricNumber(value) {
  if (value === "" || value === undefined || value === null) {
    return null;
  }

  const numeric = Number(value);
  return Number.isFinite(numeric) ? numeric : null;
}

function metricChartData(rows, totalRounds = 0) {
  const rowsByRound = new Map();

  for (let round = 1; round <= totalRounds; round += 1) {
    rowsByRound.set(round, {
      round,
      accuracy: null,
      train_accuracy: null,
      loss: null,
      train_loss: null,
    });
  }

  rows.forEach((row, index) => {
    const round = toMetricNumber(row.round) ?? index + 1;
    const chartRow = rowsByRound.get(round) || {
      round,
      accuracy: null,
      train_accuracy: null,
      loss: null,
      train_loss: null,
    };

    ["accuracy", "train_accuracy", "loss", "train_loss"].forEach((key) => {
      const value = toMetricNumber(row[key]);
      if (value !== null) {
        chartRow[key] = value;
      }
    });

    rowsByRound.set(round, chartRow);
  });

  const chartRows = [...rowsByRound.values()].sort(
    (left, right) => left.round - right.round
  );
  const hasValues = chartRows.some((row) =>
    ["accuracy", "train_accuracy", "loss", "train_loss"].some(
      (key) => row[key] !== null
    )
  );

  return hasValues ? chartRows : [];
}

function scenarioState(scenarioId, activeScenarioId, executionStatus) {
  if (scenarioId !== activeScenarioId) {
    return "NOT STARTED";
  }
  if (executionStatus === "running") {
    return "ACTIVE";
  }
  if (executionStatus === "completed") {
    return "COMPLETED";
  }
  if (["failed", "error"].includes(executionStatus)) {
    return "FAILED";
  }
  return "NOT STARTED";
}

function admissionSummary(status) {
  if (status.active_envelope_id && status.backend_bound) {
    return {
      value: "ALLOW",
      detail: "Envelope bound",
      tone: "success",
    };
  }
  if (status.active_envelope_id) {
    return {
      value: "PENDING",
      detail: "Backend binding",
      tone: "warning",
    };
  }
  return {
    value: "PENDING",
    detail: "No active envelope",
    tone: "neutral",
  };
}

function participantSummary(participants, registeredClients) {
  const labels = new Map(
    participants.map((participant) => [
      participant.org_id,
      participant.label || participant.org_id,
    ])
  );
  const liveParticipants = registeredClients.map(
    (orgId) => labels.get(orgId) || orgId
  );

  if (liveParticipants.length) {
    return liveParticipants.join(" + ");
  }

  const configuredParticipants = participants
    .filter((participant) => participant.enabled !== false)
    .map((participant) => participant.label || participant.org_id);
  return configuredParticipants.length ? configuredParticipants.join(" + ") : "—";
}

function actorVisibleInScenario(actor, scenarioId) {
  const modes = actor.modes || [];
  return !modes.length || modes.includes(scenarioId);
}

function trainingPhaseForScenario(scenarioId) {
  if (scenarioId === "ab") {
    return "AB_BASE";
  }
  if (scenarioId === "mode1a") {
    return "MODE1A";
  }
  throw new Error(`Scenario ${scenarioId} does not support training`);
}

function ScenarioStrip({
  activeScenarioId,
  executionStatus,
  onSelect,
  mode1bUseCase,
  onMode1bUseCaseChange,
}) {
  return (
    <section className="scenario-section" aria-labelledby="scenario-heading">
      <div className="section-heading">
        <div>
          <span className="eyebrow">GOVERNED LIFECYCLE</span>
          <h2 id="scenario-heading">Collaboration scenario</h2>
        </div>
        <p>
          Three bounded contexts, one evidence trail.
        </p>
      </div>

      <div className="scenario-grid">
        {SCENARIOS.map((scenario, index) => {
          const isActive = scenario.id === activeScenarioId;
          const state = scenarioState(
            scenario.id,
            activeScenarioId,
            executionStatus
          );
          return (
            <article
              aria-current={isActive ? "true" : undefined}
              aria-pressed={isActive}
              className={`scenario-card ${isActive ? "selected" : ""}`}
              key={scenario.id}
              onClick={() => onSelect(scenario.id)}
              onKeyDown={(event) => {
                if (event.key === "Enter" || event.key === " ") {
                  event.preventDefault();
                  onSelect(scenario.id);
                }
              }}
              role="button"
              tabIndex={0}
            >
              <div className="scenario-card-top">
                <span className="scenario-number">0{index + 1}</span>
                <span className={`state-badge ${state.toLowerCase().replace(" ", "-")}`}>
                  {state}
                </span>
              </div>
              <h3>{scenario.title}</h3>
              <strong className="scenario-organisations">
                {scenario.organisations}
              </strong>
              {scenario.id === "mode1b" ? (
                <>
                  <div
                    className="mode1b-use-case-selector"
                    onClick={(event) => event.stopPropagation()}
                  >
                    <span>Use case</span>

                    <button
                      className={mode1bUseCase === "governance" ? "selected" : ""}
                      onClick={() => onMode1bUseCaseChange("governance")}
                      type="button"
                    >
                      Governance Agent
                    </button>

                    <button
                      className={mode1bUseCase === "llm" ? "selected" : ""}
                      onClick={() => onMode1bUseCaseChange("llm")}
                      type="button"
                    >
                      LLM Agent
                    </button>
                  </div>

                  <p className="scenario-actors">
                    <span>Agent</span>
                    Hal
                  </p>

                  {mode1bUseCase === "llm" ? (
                    <p className="scenario-actors">
                      <span>Requesters</span>
                      Audrey · Bob
                    </p>
                  ) : null}

                  <p className="scenario-detail">
                    {mode1bUseCase === "governance"
                      ? "Bounded AI task · reuse A+B+C"
                      : "Agent-mediated request · reuse A+B+C"}
                  </p>
                </>
              ) : (
                <>
                  <p className="scenario-actors">
                    <span>People</span>
                    {scenario.actors}
                  </p>
                  <p className="scenario-detail">{scenario.detail}</p>
                </>
              )}
            </article>
          );
        })}
      </div>
    </section>
  );
}

function Overview({
  status,
  participants,
  registeredClients,
  expectedRegisteredClients,
  activeScenario,
  lastRefresh,
}) {
  const admission = admissionSummary(status);
  const cards = [
    {
      label: "Active scenario",
      value: activeScenario.title,
      detail: activeScenario.organisations,
    },
    {
      label: "Envelope ID",
      value: status.active_envelope_id || "Not bound",
      detail: status.backend_bound ? "Backend bound" : "Awaiting binding",
      mono: Boolean(status.active_envelope_id),
    },
    {
      label: "Run / model ID",
      value: status.model_run_id || "No trained model",
      detail: status.model_run_id ? "Selected envelope model" : "Training required",
      mono: true,
    },
    {
      label: "Participants",
      value: participantSummary(participants, registeredClients),
      detail: `${registeredClients.length} of ${expectedRegisteredClients} registered`,
    },
    {
      label: "Execution status",
      value: status.status || "Connecting",
      detail: lastRefresh ? `Updated ${lastRefresh}` : "Waiting for Hub",
      tone: status.status === "running" ? "active" : undefined,
    },
    {
      label: "Admission decision",
      value: admission.value,
      detail: admission.detail,
      tone: admission.tone,
    },
  ];

  return (
    <section className="overview-section" aria-labelledby="overview-heading">
      <div className="section-heading compact">
        <div>
          <span className="eyebrow">OPERATIONAL VIEW</span>
          <h2 id="overview-heading">Current governed state</h2>
        </div>
      </div>

      <div className="overview-grid">
        {cards.map((card) => (
          <article className={`overview-card ${card.tone || ""}`} key={card.label}>
            <span>{card.label}</span>
            <strong className={card.mono ? "mono" : ""}>{card.value}</strong>
            <small>{card.detail}</small>
          </article>
        ))}
      </div>

      <div className="governance-banner">
        <div className="governance-mark" aria-hidden="true">✓</div>
        <div>
          <strong>FCaC admission enabled</strong>
          <p>{activeScenario.statement}</p>
        </div>
        <div className="separation-principle">
          Admission <b>≠</b> Authentication <b>≠</b> Authorization
        </div>
      </div>
    </section>
  );
}

function ModeSelector({ mode, onChange }) {
  return (
    <section className="mode-selector" aria-label="Operational role">
      <div>
        <span className="eyebrow">DASHBOARD ROLE</span>
        <strong>{mode === "administration" ? "Collaboration administration" : "Participant operations"}</strong>
      </div>
      <div className="mode-buttons" role="tablist" aria-label="Dashboard mode">
        {[
          ["administration", "Administration"],
          ["user", "User"],
        ].map(([id, label]) => (
          <button
            aria-selected={mode === id}
            className={mode === id ? "active" : ""}
            key={id}
            onClick={() => onChange(id)}
            role="tab"
            type="button"
          >
            {label}
          </button>
        ))}
      </div>
    </section>
  );
}

function formatEnvelopeTime(value) {
  if (!value) return "Not reported";
  const numeric = Number(value);
  const date = Number.isFinite(numeric)
    ? new Date(numeric > 1e12 ? numeric : numeric * 1000)
    : new Date(value);
  return Number.isNaN(date.getTime()) ? String(value) : date.toLocaleString();
}

function formatActorMode(mode) {
  if (mode === "ab") return "A+B";
  if (mode === "mode1a") return "Mode 1A";
  if (mode === "mode1b") return "Mode 1B";
  return mode;
}

function BoundaryControlArea({
  administration,
  ceremony,
  onBegin,
  onApprove,
  onSelect,
  onMint,
  busy,
  error,
}) {
  const [codes, setCodes] = useState({ "hospital-a": "", "hospital-b": "" });
  const registry = administration.envelopes || [];
  const approvals = ceremony.approvals || {};
  const selectedId = administration.selected_envelope_id;
  const selected = registry.find((envelope) => envelope.envelope_id === selectedId) || null;
  const holders = administration.holders || [];

  const organisations = [
    { id: "hospital-a", uri: "org://HospitalA", label: "Hospital A" },
    { id: "hospital-b", uri: "org://HospitalB", label: "Hospital B" },
  ];

  function updateCode(id, value) {
    setCodes((current) => ({
      ...current,
      [id]: value.replace(/\D/g, "").slice(0, 6),
    }));
  }

  return (
    <section className="administration-section" aria-labelledby="envelopes-heading">
      <div className="section-heading">
        <div>
          <span className="eyebrow">ADMINISTRATION · ENVELOPES</span>
          <h2 id="envelopes-heading">Select the collaboration boundary</h2>
        </div>
        <p>Choose an existing active envelope, review its state, and inspect the actors and capabilities reported by the Hub.</p>
      </div>

      <div className="boundary-control-shell">
        <div className="boundary-selector-row">
          <label className="compact-select">
            <span>{registry.length ? "Valid active envelope" : "No active envelopes"}</span>
            <select onChange={(event) => onSelect(event.target.value)} value={selectedId || ""}>
              <option disabled value="">Select an envelope</option>
              {registry.map((envelope) => (
                <option key={envelope.envelope_id} value={envelope.envelope_id}>
                  {envelope.envelope_id}
                </option>
              ))}
            </select>
          </label>
          <dl className="boundary-facts">
            <div><dt>Bound</dt><dd>{selected ? (selected.bound ? "Yes" : "No") : "—"}</dd></div>
            <div><dt>Expiry</dt><dd>{selected ? formatEnvelopeTime(selected.expiry) : "—"}</dd></div>
            <div><dt>Model</dt><dd>{selected ? (selected.model_available ? "Available" : "Training required") : "—"}</dd></div>
            <div><dt>Run</dt><dd className="mono">{selected?.model_run_id || "—"}</dd></div>
          </dl>
        </div>

        <div className="capability-table-scroll">
          <table className="capability-table">
            <thead>
              <tr>
                <th>User</th>
                <th>Organization</th>
                <th>Enrollment</th>
                <th>ECT</th>
                <th>Preview</th>
                <th>Expiry</th>
                <th aria-label="ECT action" />
              </tr>
            </thead>
            <tbody>
              {holders.map((holder) => {
                const enrollmentLabel = holder.enrollment_status === "planned"
                  ? "Planned"
                  : holder.enrollment_status === "unavailable"
                  ? "Issuer unavailable"
                  : holder.enrolled
                  ? "Enrolled"
                  : "Not enrolled";
                const ectLabel = holder.ect_status === "ready"
                  ? "Ready"
                  : holder.ect_status === "expired"
                  ? "Expired"
                  : holder.ect_status === "unavailable"
                  ? "Not operational"
                  : "Not ready";
                return (
                  <tr key={holder.principal}>
                    <td>
                      <strong>{holder.principal}</strong>
                      <span className="actor-meta">
                        {holder.actor_type || "actor"} · {holder.actor_status || "unknown"}
                        {holder.modes?.length
                          ? ` · ${holder.modes.map(formatActorMode).join(", ")}`
                          : ""}
                      </span>
                    </td>
                    <td>{holder.organization}</td>
                    <td>{enrollmentLabel}</td>
                    <td>{ectLabel}</td>
                    <td className="mono">{holder.ect_preview || "—"}</td>
                    <td>{holder.expires_at ? formatEnvelopeTime(holder.expires_at) : "—"}</td>
                    <td>
                      <button
                        disabled={busy || holder.can_mint !== true}
                        onClick={() => onMint(holder.principal)}
                        type="button"
                      >
                        {holder.actor_status !== "active"
                          ? "PLANNED"
                          : holder.ect_status === "ready"
                          ? "REMINT ECT"
                          : "MINT ECT"}
                      </button>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </div>

      <details className="kyo-disclosure">
        <summary>Create another envelope · KYO</summary>
        <div className="ceremony-controls">
          <div className="ceremony-heading">
            <div>
              <span className="eyebrow">CREATE ANOTHER ENVELOPE · KYO</span>
              <h3>Hospital A + Hospital B · quorum 2 of 2</h3>
            </div>
            <button
              className="primary-action"
              disabled={busy || Boolean(ceremony.bind_id)}
              onClick={onBegin}
              type="button"
            >
              {ceremony.bind_id ? "CEREMONY IN PROGRESS" : "BEGIN KYO CEREMONY"}
            </button>
          </div>

          {ceremony.bind_id ? (
            <p className="ceremony-bind">Bind evidence <code>{ceremony.bind_id}</code></p>
          ) : <p className="ceremony-description">Begin only when a new collaboration envelope is required.</p>}

          {ceremony.bind_id && !ceremony.envelope_id ? organisations.map((organisation, index) => {
            const approved = approvals[organisation.uri];
            const previousApproved =
            index === 0 || Boolean(approvals[organisations[index - 1].uri]);  

            return (
              <div className={`organisation-approval ${approved ? "approved" : ""}`} key={organisation.id}>
                <div>
                  <strong>{organisation.label} administrator</strong>
                  <span>{approved ? `${approved.admin_cn || organisation.uri} · verified and approved` : organisation.uri}</span>
                </div>
                <input
                  aria-label={`${organisation.label} six-digit code`}
                  disabled={busy || Boolean(approved)  || !previousApproved} 
                  inputMode="numeric"
                  onChange={(event) => updateCode(organisation.id, event.target.value)}
                  placeholder="000000"
                  value={codes[organisation.id]}
                />
                <button
                  disabled={ busy ||
                             Boolean(approved) ||
                              !previousApproved ||
                              codes[organisation.id].length !== 6
                            }

                  onClick={() => onApprove(organisation.id, codes[organisation.id])}
                  type="button"
                >
                  {approved ? "APPROVED" : "VERIFY AND APPROVE"}
                </button>
              </div>
            );
          }) : null}

          {ceremony.envelope_id ? (
            <div className="ceremony-result">
              Envelope created: <code>{ceremony.envelope_id}</code>. Registry and backend state are reported above.
            </div>
          ) : null}
          {error ? <div className="ceremony-error">{error}</div> : null}
        </div>
      </details>
    </section>
  );
}

 
function UserModePanel({
  administration,
  selectedPrincipal,
  selectedTissue,
  onPrincipalChange,
  onTissueChange,
  onRunInference,
  busy,
  error,
  result,
  scenarioId,
  mode1bUseCase,
  requesterPrincipal,
  onRequesterChange,
}) {
  const selectedId = administration.selected_envelope_id;

  const selectedEnvelope = (administration.envelopes || []).find(
    (envelope) => envelope.envelope_id === selectedId
  );

  const inferenceActors = administration.inference_actors || [];

  const holder =
    (administration.holders || []).find(
      (item) => item.principal === selectedPrincipal
    ) || null;

  const mode1b = scenarioId === "mode1b";
  const llmAgent = mode1b && mode1bUseCase === "llm";

  const requesters = llmAgent
    ? (administration.holders || []).filter(
        (actor) => (actor.modes || []).includes("ab")
      )
    : [];

  const requesterHolder = llmAgent
    ? (administration.holders || []).find(
        (actor) => actor.principal === requesterPrincipal
      ) || null
    : null;

  const halHolder = llmAgent
    ? (administration.holders || []).find(
        (actor) => actor.principal === "Hal"
      ) || null
    : null;

  const requesterEctReady =
    requesterHolder?.ect_status === "ready";

  const halEctReady =
    halHolder?.ect_status === "ready";

  const llmAgentReady =
    llmAgent && requesterEctReady && halEctReady;

  const tissueOptions = mode1b ? MODE1B_TISSUES : USER_TISSUES;
  const activeAdmission = llmAgent
    ? result?.source_admission
    : result?.admission;
  const prediction = result?.prediction || null;
  const presentedImage =
    llmAgent && result?.representation === "derivative"
      ? prediction?.derivative_image
      : prediction?.sample_image;

  const presentedImageSrc = presentedImage?.image_b64
    ? `data:${presentedImage.mime_type || "image/png"};base64,${
        presentedImage.image_b64
      }`
    : null;

  return (
    <div className="governed-inference">
      <div className="user-mode-layout">
        <div className="workspace-controls">
          <p>
            Use the administrator-minted ECT for the selected boundary.
            Each request generates fresh DPoP before Gatekeeper admission.
          </p>

          {llmAgent && (
            <>
              <label>
                Requester
                <select
                  value={requesterPrincipal}
                  onChange={(event) =>
                    onRequesterChange(event.target.value)
                  }
                >
                  {requesters.map((actor) => (
                    <option
                      key={actor.principal}
                      value={actor.principal}
                    >
                      {actor.principal}
                    </option>
                  ))}
                </select>
              </label>

              <label>
                Agent
                <input value="Hal" readOnly />
              </label>
            </>
          )}

          {!llmAgent && (
            <>
              <label className="compact-select">
                <span>Holder</span>
                <select
                  disabled={!inferenceActors.length}
                  onChange={(event) =>
                    onPrincipalChange(event.target.value)
                  }
                  value={selectedPrincipal}
                >
                  {!inferenceActors.length ? (
                    <option value="">
                      No operational holders
                    </option>
                  ) : null}

                  {inferenceActors.map((actor) => (
                    <option
                      key={actor.principal}
                      value={actor.principal}
                    >
                      {actor.principal} · {actor.organization}
                    </option>
                  ))}
                </select>
              </label>
            </>
          )}

          <label className="compact-select">
            <span>Tissue</span>
            <select
              onChange={(event) =>
                onTissueChange(event.target.value)
              }
              value={selectedTissue}
            >
              {tissueOptions.map((tissue) => (
                <option key={tissue} value={tissue}>
                  {tissue}
                </option>
              ))}
            </select>
          </label>

          <button
            disabled={
              busy ||
              !selectedId ||
              (llmAgent
                ? !llmAgentReady
                : !holder || holder.ect_status !== "ready")
            }
            onClick={onRunInference}
            type="button"
          >
            {llmAgent
              ? "RUN LLM AGENT REQUEST"
              : mode1b
              ? "RUN HAL BOUNDED INFERENCE"
              : "RUN GOVERNED INFERENCE"}
          </button>
        </div>

        <div className="user-mode-result-card">
          <div>
            <span className="eyebrow">BOUNDARY</span>
            <strong className="mono">
              {selectedId || "No envelope selected"}
            </strong>
          </div>

          <div>
            <span className="eyebrow">ECT STATUS</span>
            <strong>
              {holder
                ? holder.ect_status === "ready"
                  ? "Ready"
                  : holder.ect_status === "expired"
                  ? "Expired"
                  : "Not ready"
                : "Unavailable"}
            </strong>
          </div>

          <div>
            <span className="eyebrow">MODEL RUN</span>
            <strong className="mono">
              {result?.model_run_id ||
                result?.hal_inference?.model_run_id ||
                selectedEnvelope?.model_run_id ||
                "—"}
            </strong>
          </div>

          <div>
            <span className="eyebrow">ADMISSION</span>
            <strong>
              {result
                ? activeAdmission?.allow
                  ? "ALLOW"
                  : "DENY"
                : "Awaiting request"}
            </strong>
          </div>

          {activeAdmission?.reason ? (
            <div>
              <span className="eyebrow">REASON</span>
              <strong>{activeAdmission.reason}</strong>
            </div>
          ) : null}

          {llmAgent && result?.agent_decision?.action ? (
            <div>
              <span className="eyebrow">HAL ACTION</span>
              <strong>{result.agent_decision.action}</strong>
            </div>
          ) : null}

          {llmAgent && result?.rebind_admission ? (
            <div>
              <span className="eyebrow">REBIND</span>
              <strong>
                {result.rebind_admission.allow ? "ALLOW" : "DENY"}
              </strong>
            </div>
          ) : null}

          {llmAgent && result?.representation ? (
            <div>
              <span className="eyebrow">REPRESENTATION</span>
              <strong>{result.representation}</strong>
            </div>
          ) : null}

          {prediction ? (
            <div className="prediction-result">
              {presentedImageSrc ? (
                <img
                  alt={`PathMNIST sample for ${
                    prediction.requested_tissue
                  }`}
                  height={presentedImage.height || 28}
                  src={presentedImageSrc}
                  width={presentedImage.width || 28}
                />
              ) : null}

              <dl>
                <div>
                  <dt>Requested tissue</dt>
                  <dd>
                    {prediction.requested_tissue || "—"}
                  </dd>
                </div>

                <div>
                  <dt>Actual label</dt>
                  <dd>
                    {prediction.actual_label ?? "—"}
                  </dd>
                </div>

                <div>
                  <dt>Predicted tissue</dt>
                  <dd>
                    {prediction.prediction_tissue || "—"}
                  </dd>
                </div>
              </dl>

              {prediction.topk?.length ? (
                <ol>
                  {prediction.topk.map((entry) => (
                    <li
                      key={`${entry.label}-${entry.tissue}`}
                    >
                      <span>{entry.tissue}</span>
                      <strong>
                        {Number(entry.probability).toFixed(4)}
                      </strong>
                    </li>
                  ))}
                </ol>
              ) : null}
            </div>
          ) : null}

          {error ? (
            <div className="ceremony-error">{error}</div>
          ) : null}
        </div>
      </div>
    </div>
  );
} 
 

function MetricsTable({ rows }) {
  if (!rows.length) {
    return <div className="empty-state">No metrics available yet.</div>;
  }

  return (
    <div className="table-scroll">
      <table>
        <thead>
          <tr>
            <th>Round</th>
            <th>Clients</th>
            <th>Failures</th>
            <th>Loss</th>
            <th>Accuracy</th>
            <th>Train loss</th>
            <th>Train accuracy</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((row, index) => (
            <tr key={`${row.round || "round"}-${index}`}>
              <td>{row.round || "—"}</td>
              <td>{row.client_count ?? row.fit_client_count ?? "—"}</td>
              <td>{row.failure_count ?? "—"}</td>
              <td>{row.loss || "—"}</td>
              <td>{row.accuracy || "—"}</td>
              <td>{row.train_loss || "—"}</td>
              <td>{row.train_accuracy || "—"}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function MetricLineChart({ title, data, series }) {
  const hasValues = data.some((row) =>
    series.some(({ key }) => row[key] !== null)
  );

  return (
    <div className="chart-card">
      <h4>{title}</h4>
      {data.length ? (
        <div className="chart-frame">
          <ResponsiveContainer width="100%" height="100%">
            <LineChart data={data} margin={{ top: 8, right: 20, bottom: 4, left: 0 }}>
              <CartesianGrid stroke="#dbe5ec" strokeDasharray="3 3" />
              <XAxis
                dataKey="round"
                label={{ value: "Round", position: "insideBottom", offset: -2 }}
                tickLine={false}
                stroke="#617080"
              />
              <YAxis tickLine={false} stroke="#617080" width={46} />
              <Tooltip />
              <Legend verticalAlign="top" height={32} />
              {series.map(({ key, label, color }) => (
                <Line
                  connectNulls
                  dataKey={key}
                  dot={{ r: 3 }}
                  key={key}
                  name={label}
                  stroke={color}
                  strokeWidth={2}
                  type="monotone"
                />
              ))}
            </LineChart>
          </ResponsiveContainer>
        </div>
      ) : null}
      {!hasValues ? <p className="muted">No chartable values yet.</p> : null}
    </div>
  );
}

function MetricsCharts({ rows, totalRounds }) {
  const data = useMemo(() => metricChartData(rows, totalRounds), [rows, totalRounds]);

  if (!data.length) {
    return null;
  }

  return (
    <div className="charts-grid">
      <MetricLineChart
        title="Accuracy over rounds"
        data={data}
        series={[
          { key: "accuracy", label: "Accuracy", color: "#126782" },
          { key: "train_accuracy", label: "Train accuracy", color: "#2a9d8f" },
        ]}
      />
      <MetricLineChart
        title="Loss over rounds"
        data={data}
        series={[
          { key: "loss", label: "Loss", color: "#d1495b" },
          { key: "train_loss", label: "Train loss", color: "#8b5cf6" },
        ]}
      />
    </div>
  );
}

function EventsTimeline({ events }) {
  if (!events.length) {
    return <div className="empty-state">No events available yet.</div>;
  }

  return (
    <div className="event-list">
      {[...events].reverse().map((event, index) => (
        <details key={`${event.timestamp || "event"}-${index}`}>
          <summary>
            <span className="event-type">{event.event_type || "event"}</span>
            <span>{event.component || "component"}</span>
            <time>{event.timestamp || ""}</time>
          </summary>
          <pre>{JSON.stringify(event, null, 2)}</pre>
        </details>
      ))}
    </div>
  );
}

function ClientsTable({ participants, registeredClients }) {
  const rows = useMemo(() => {
    const configured = participants.map((participant) => ({
      ...participant,
      configured: true,
    }));
    const configuredIds = new Set(configured.map((participant) => participant.org_id));
    const liveOnly = registeredClients
      .filter((orgId) => !configuredIds.has(orgId))
      .map((orgId) => ({
        org_id: orgId,
        label: orgId,
        partition: null,
        enabled: true,
        configured: false,
      }));
    return [...configured, ...liveOnly];
  }, [participants, registeredClients]);

  if (!rows.length) {
    return <div className="empty-state">No participants available.</div>;
  }

  return (
    <div className="table-scroll">
      <table>
        <thead>
          <tr>
            <th>Organisation</th>
            <th>Participant</th>
            <th>Partition</th>
            <th>Configured</th>
            <th>Registered</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((client) => (
            <tr key={client.org_id}>
              <td className="mono">{client.org_id}</td>
              <td>{client.label || "—"}</td>
              <td>{client.partition ?? "—"}</td>
              <td>
                <span className={`status-chip ${client.enabled ? "ok" : "off"}`}>
                  {client.configured && client.enabled ? "Enabled" : "No"}
                </span>
              </td>
              <td>
                <span
                  className={`status-chip ${
                    registeredClients.includes(client.org_id) ? "ok" : "waiting"
                  }`}
                >
                  {registeredClients.includes(client.org_id) ? "Live" : "Waiting"}
                </span>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function EvidenceArtifacts({ status }) {
  const artefacts = [
    "experiment_config.json",
    "participants.json",
    "dataset_split_summary.csv",
    "metrics.csv",
    "events.jsonl",
    "final_model_metadata.json",
    "README_reproduce_this_run.md",
  ];

  return (
    <div className="evidence-layout">
      <div className="evidence-status">
        <span className="eyebrow">LIVE GOVERNANCE CONTEXT</span>
        <dl>
          <div>
            <dt>Envelope</dt>
            <dd className="mono">{status.active_envelope_id || "Not bound"}</dd>
          </div>
          <div>
            <dt>Backend binding</dt>
            <dd>{status.backend_bound ? "Bound" : "Pending"}</dd>
          </div>
          <div>
            <dt>Start decision</dt>
            <dd>{status.can_start ? "Ready" : "Conditions incomplete"}</dd>
          </div>
        </dl>
        <p>
          ECT, DPoP and admission decisions belong in the governed event trail;
          this view does not manufacture evidence that the Hub has not reported.
        </p>
      </div>
      <div>
        <h4>Run artefacts</h4>
        <p className="muted">
          {status.model_run_id
            ? <>Current model under <code>runs/{status.model_run_id}/</code></>
            : "No completed model run is associated with this envelope."}
        </p>
        <ul className="artefact-list">
          {artefacts.map((artefact) => (
            <li key={artefact}><code>{artefact}</code></li>
          ))}
        </ul>
      </div>
    </div>
  );
}

function ConfigurationPanel({
  config,
  editableConfig,
  onEditableConfigChange,
  configEditable,
  onStartExperiment,
  starting,
  canStart,
  scenarioId,
  modelRunId,
}) {
  const trainingEnabled = scenarioId !== "mode1b";
  const actionLabel = modelRunId
    ? "RETRAIN MODEL"
    : "START TRAINING";

  return (
    <div className="configuration-layout">
      <section className="control-card">
        <span className="eyebrow">TRAINING CONTROLS</span>
        <h4>Federated run</h4>
        {trainingEnabled ? (
          <p>
            {modelRunId
              ? <>This envelope currently uses <code>{modelRunId}</code>. The model can be reused, or retrained to create the next run.</>
              : "This envelope has no trained model. Training is required before model use."}
          </p>
        ) : (
          <p>
            Mode 1B reuses the A+B+C model. Hal participates only in its bounded task;
            no training START is available in this mode.
          </p>
        )}
        <div className="control-grid">
          <label>
            <span>Rounds</span>
            <input
              disabled={!configEditable || !trainingEnabled}
              min="1"
              name="rounds"
              onChange={onEditableConfigChange}
              type="number"
              value={editableConfig.rounds || 1}
            />
          </label>
          <label>
            <span>Local epochs</span>
            <input
              disabled={!configEditable || !trainingEnabled}
              min="1"
              name="local_epochs"
              onChange={onEditableConfigChange}
              type="number"
              value={editableConfig.local_epochs || 1}
            />
          </label>
        </div>
        <button
          id="startButton"
          type="button"
          onClick={onStartExperiment}
          disabled={starting || !canStart || !trainingEnabled}
        >
          {starting ? "STARTING…" : trainingEnabled ? actionLabel : "MODEL REUSE · NO START"}
        </button>
        {trainingEnabled && !canStart ? (
          <small className="control-note">
            Waiting for the envelope, backend binding and required clients.
          </small>
        ) : null}
      </section>

      <section className="config-card">
        <div className="config-card-heading">
          <div>
            <span className="eyebrow">HUB RESPONSE</span>
            <h4>Active experiment configuration</h4>
          </div>
          <span className="status-chip ok">
            {config.governance?.pass_through === false ? "FCaC enforced" : "Reported state"}
          </span>
        </div>
        <pre>{JSON.stringify(config, null, 2)}</pre>
      </section>
    </div>
  );
}

function TabPanel({
  activeTab,
  metrics,
  events,
  participants,
  registeredClients,
  config,
  chartRounds,
  status,
  editableConfig,
  onEditableConfigChange,
  configEditable,
  onStartExperiment,
  starting,
  scenarioId,
  canTrain,
  modelRunId,
  userModePanel,
}) {
  const totalRounds = Number(chartRounds || config.rounds || config.flower_rounds || 0);
  const trainingRound = toMetricNumber(status.training?.round);
  const reportedRound = status.status === "running" && trainingRound !== null
    ? trainingRound
    : latestRound(metrics);
  const liveAccuracy = toMetricNumber(status.training?.overall_accuracy);
  const reportedAccuracy = status.status === "running" && liveAccuracy !== null
    ? liveAccuracy.toFixed(4)
    : formatMetric(metrics, "accuracy");

  return (
    <>
      <section className={`panel ${activeTab === "metrics" ? "" : "hidden"}`}>
        <div className="panel-heading">
          <div>
            <span className="eyebrow">TRAINING AND EVALUATION</span>
            <h3>Metrics</h3>
          </div>
          <span className="metric-summary">
            Envelope{" "}
            <code title={status.active_envelope_id || ""}>
              {compactIdentifier(status.active_envelope_id)}
            </code>
            {" "}· Round {reportedRound} · Accuracy {reportedAccuracy}
          </span>
        </div>
        <MetricsCharts rows={metrics} totalRounds={totalRounds} />
        <MetricsTable rows={metrics} />
      </section>

      <section className={`panel ${activeTab === "events" ? "" : "hidden"}`}>
        <div className="panel-heading">
          <div>
            <span className="eyebrow">EVIDENCE TRAIL</span>
            <h3>Events</h3>
          </div>
          <span className="metric-summary">{events.length} reported</span>
        </div>
        <EventsTimeline events={events} />
      </section>

      <section className={`panel ${activeTab === "clients" ? "" : "hidden"}`}>
        <div className="panel-heading">
          <div>
            <span className="eyebrow">FEDERATION STATE</span>
            <h3>Clients</h3>
          </div>
          <span className="metric-summary">Configured and live registration</span>
        </div>
        <ClientsTable
          participants={participants}
          registeredClients={registeredClients}
        />
      </section>

      <section className={`panel ${activeTab === "training" ? "" : "hidden"}`}>
        <div className="panel-heading">
          <div>
            <span className="eyebrow">ADMINISTRATION OPERATION</span>
            <h3>Training</h3>
          </div>
        </div>
        <ConfigurationPanel
          config={config}
          editableConfig={editableConfig}
          onEditableConfigChange={onEditableConfigChange}
          configEditable={configEditable}
          onStartExperiment={onStartExperiment}
          starting={starting}
          canStart={canTrain}
          scenarioId={scenarioId}
          modelRunId={modelRunId}
        />
      </section>

      <section className={`panel ${activeTab === "model-use" ? "" : "hidden"}`}>
        <div className="panel-heading">
          <div>
            <span className="eyebrow">PARTICIPANT OPERATION</span>
            <h3>Model use</h3>
          </div>
        </div>
        {userModePanel}
      </section>

      <section className={`panel ${activeTab === "evidence" ? "" : "hidden"}`}>
        <div className="panel-heading">
          <div>
            <span className="eyebrow">REPRODUCIBILITY</span>
            <h3>Evidence</h3>
          </div>
        </div>
        <EvidenceArtifacts status={status} />
      </section>
    </>
  );
}

function Header({ lastRefresh }) {
  return (
    <header className="app-header">
      <div className="header-inner">
        <div className="brand">
          <img className="logo-img" src={logoUrl} alt="OpenHealth logo" />
          <div>
            <h1>OpenHealth</h1>
            <div className="brand-subtitle">Governed Federated Computing</div>
          </div>
        </div>
        <div className="header-status">
          <div className="header-principle">
            Admission <b>≠</b> Authentication <b>≠</b> Authorization
          </div>
          <div className="badges">
            <span className="badge navy">vfp-core</span>
            <span className="badge teal">FCaC admission enabled</span>
            <span className="badge outline">{APP_VERSION}</span>
            <span className="live-indicator">
              <i aria-hidden="true" /> {lastRefresh ? "Hub connected" : "Connecting"}
            </span>
          </div>
        </div>
      </div>
    </header>
  );
}

export default function App() {
  const [dashboardMode, setDashboardMode] = useState("administration");
  const [activeTab, setActiveTab] = useState("training");
  const [selectedScenarioId, setSelectedScenarioId] = useState("ab");
  const [mode1bUseCase, setMode1bUseCase] = useState("governance");
  const [status, setStatus] = useState({});
  const [experiment, setExperiment] = useState({});
  const [metrics, setMetrics] = useState([]);
  const [events, setEvents] = useState([]);
  const [lastRefresh, setLastRefresh] = useState("");
  const [error, setError] = useState("");
  const [starting, setStarting] = useState(false);
  const [administration, setAdministration] = useState({
    envelopes: [],
    holders: [],
    inference_actors: [],
  });
  const [ceremony, setCeremony] = useState({ approvals: {} });
  const [administrationBusy, setAdministrationBusy] = useState(false);
  const [administrationError, setAdministrationError] = useState("");
  const [userPrincipal, setUserPrincipal] = useState("Audrey");
  const [requesterPrincipal, setRequesterPrincipal] = useState("Audrey");
  const [userTissue, setUserTissue] = useState("lymphocytes");
  const [userBusy, setUserBusy] = useState(false);
  const [userError, setUserError] = useState("");
  const [userInferenceResult, setUserInferenceResult] = useState(null);
  const [editableConfig, setEditableConfig] = useState({
    rounds: 1,
    local_epochs: 1,
  });
  const pollIntervalRef = useRef(null);
  const configDirtyRef = useRef(false);

  const config = experiment.experiment_config || {};
  const canTrain = Boolean(
    status.active_envelope_id
    && status.backend_bound
    && (status.registered_client_count || 0) >= (status.min_clients || 0)
    && status.status !== "running"
    && !starting
  );
  const configEditable = canTrain;
  const participants = useMemo(
    () => experiment.participants?.participants || [],
    [experiment.participants]
  );
  const registeredClients = status.registered_clients || [];
  const activeScenarioId = selectedScenarioId;
  const activeScenario =
    SCENARIOS.find((scenario) => scenario.id === activeScenarioId) || SCENARIOS[0];
  const scenarioParticipants = useMemo(
    () =>
      participants.filter((participant) =>
        activeScenario.participantOrgIds.includes(participant.org_id)
      ),
    [participants, activeScenario]
  );
  const scenarioRegisteredClients = registeredClients.filter((orgId) =>
    activeScenario.participantOrgIds.includes(orgId)
  );


  const scenarioAdministration = useMemo(
  () => ({
    ...administration,
    holders: (administration.holders || []).filter((actor) => {
      if (activeScenarioId === "mode1b" && mode1bUseCase === "llm") {
        return (
          actorVisibleInScenario(actor, "mode1b") ||
          actorVisibleInScenario(actor, "ab")
        );
      }

      return actorVisibleInScenario(actor, activeScenarioId);
    }),
    inference_actors: (administration.inference_actors || []).filter((actor) =>
      actorVisibleInScenario(actor, activeScenarioId)
    ),
  }),
  [administration, activeScenarioId, mode1bUseCase]
);


  const selectedModelRunId = (administration.envelopes || []).find(
    (envelope) => envelope.envelope_id === administration.selected_envelope_id
  )?.model_run_id;
  const displayedModelRunId = status.status === "running"
    ? status.model_run_id
    : selectedModelRunId || status.model_run_id;
  const displayedStatus = {
    ...status,
    model_run_id: displayedModelRunId,
  };
  const visibleTabs = dashboardMode === "administration" ? ADMIN_TABS : USER_TABS;

  function clearPollInterval() {
    if (pollIntervalRef.current !== null) {
      window.clearInterval(pollIntervalRef.current);
      pollIntervalRef.current = null;
    }
  }

  async function refreshAdministration() {
    try {
      const boundary = await getJson("/administration/boundary");
      setAdministration(boundary);
      setAdministrationError("");
    } catch (err) {
      setAdministrationError(err.message);
      console.error(err);
    }
  }

  async function refreshAll() {
    try {
      const [statusPayload, experimentPayload, metricsPayload, eventsPayload] =
        await Promise.all([
          getJson(`/experiments/${RUN_ID}/status`),
          getJson(`/experiments/${RUN_ID}`),
          getJson(`/experiments/${RUN_ID}/metrics`),
          getJson(`/experiments/${RUN_ID}/events?limit=150`),
        ]);

      setStatus(statusPayload);
      setExperiment(experimentPayload);
      const metricsMatchActiveRun = Boolean(statusPayload.model_run_id)
        && metricsPayload.model_run_id === statusPayload.model_run_id;
      setMetrics(metricsMatchActiveRun ? metricsPayload.metrics || [] : []);
      setEvents(eventsPayload.events || []);
      if (!configDirtyRef.current) {
        setEditableConfig({
          rounds: experimentPayload.experiment_config?.rounds || 1,
          local_epochs: experimentPayload.experiment_config?.local_epochs || 1,
        });
      }
      setLastRefresh(new Date().toLocaleTimeString());
      setError("");
      await refreshAdministration();

    } catch (err) {
      setStatus((current) => ({ ...current, status: "error" }));
      setError(err.message);
      console.error(err);
    }
  }

  async function beginKyoCeremony() {
    setAdministrationBusy(true);
    setAdministrationError("");
    try {
      const result = await postJson("/administration/kyo/binds");
      setCeremony({
        bind_id: result.bind_id,
        policy_hash: result.policy_hash,
        approvals: {},
      });
    } catch (err) {
      setAdministrationError(err.message);
      console.error(err);
    } finally {
      setAdministrationBusy(false);
    }
  }

  async function approveKyoOrganisation(organisation, code) {
    setAdministrationBusy(true);
    setAdministrationError("");
    try {
      const result = await postJson(`/administration/kyo/${organisation}/approve`, {
        bind_id: ceremony.bind_id,
        code,
      });
      const approval = result.approval || {};

      setCeremony((current) => ({
        ...current,
        bind_id: approval.envelope_id ? null : current.bind_id,
        approvals: {
          ...current.approvals,
          [result.organization]: {
            admin_cn: result.admin_cn,
            approved: true,
          },
        },
        envelope_id: approval.envelope_id || current.envelope_id,
      }));


      await refreshAdministration();
    } catch (err) {
      setAdministrationError(err.message);
      console.error(err);
    } finally {
      setAdministrationBusy(false);
    }
  }

  async function selectEnvelope(envelopeId) {
    setAdministrationBusy(true);
    setAdministrationError("");
    try {
      await postJson(`/administration/envelopes/${envelopeId}/select`);
      await refreshAll();
    } catch (err) {
      setAdministrationError(err.message);
      console.error(err);
    } finally {
      setAdministrationBusy(false);
    }
  }

  async function mintHolderEct(principal) {
    setAdministrationBusy(true);
    setAdministrationError("");
    try {
      await postJson(`/administration/holders/${principal}/mint-ect`, {
        envelope_id: administration.selected_envelope_id,
      });
      await refreshAll();
    } catch (err) {
      setAdministrationError(err.message);
      console.error(err);
    } finally {
      setAdministrationBusy(false);
    }
  }

  async function runUserInference() {
    setUserBusy(true);
    setUserError("");
    setUserInferenceResult(null);
    try {

      const llmAgent =
        activeScenarioId === "mode1b" && mode1bUseCase === "llm";

      const governanceAgent =
        activeScenarioId === "mode1b" && mode1bUseCase === "governance";

      const inferencePath = llmAgent
        ? "/mode1b/agent/request"
        : governanceAgent
          ? "/mode1b/inference"
          : "/user/inference";

      const requestBody = llmAgent
        ? {
            requester: requesterPrincipal,
            envelope_id: administration.selected_envelope_id,
            requested_tissue: userTissue,
            topk: 3,
          }
        : {
            principal: userPrincipal,
            envelope_id: administration.selected_envelope_id,
            requested_tissue: userTissue,
            topk: 3,
          };

    const result = await postJson(inferencePath, requestBody);
      setUserInferenceResult(result);
    } catch (err) {
      setUserError(err.message);
      console.error(err);
    } finally {
      setUserBusy(false);
    }
  }

  async function startExperiment() {
    setStarting(true);
    setMetrics([]);
    try {
      await postJson(`/experiments/initialise`, {
        run_id: RUN_ID,
        dataset: config.dataset || "medmnist",
        dataset_subset: config.dataset_subset || "pathmnist",
        phase: trainingPhaseForScenario(activeScenarioId),
        rounds: Math.max(1, Number(editableConfig.rounds) || 1),
        min_clients: status.min_clients || config.min_clients || 2,
        local_epochs: Math.max(1, Number(editableConfig.local_epochs) || 1),
      });
      await postJson(`/experiments/${RUN_ID}/start`);
      await refreshAll();
    } catch (err) {
      setError(err.message);
      console.error(err);
    } finally {
      setStarting(false);
    }
  }

  function handleEditableConfigChange(event) {
    const { name, value } = event.target;
    configDirtyRef.current = true;
    setEditableConfig((current) => ({
      ...current,
      [name]: Math.max(1, Number(value) || 1),
    }));
  }

  function changeDashboardMode(mode) {
    setDashboardMode(mode);
    setActiveTab(mode === "administration" ? "training" : "model-use");
  }

  useEffect(() => {
    refreshAll();
    pollIntervalRef.current = window.setInterval(refreshAll, POLL_MS);
    return clearPollInterval;
  }, []);

  useEffect(() => {
    const actors = scenarioAdministration.inference_actors || [];
    if (!actors.length) {
      if (userPrincipal) {
        setUserPrincipal("");
        setUserInferenceResult(null);
      }
      return;
    }
    if (!actors.some((actor) => actor.principal === userPrincipal)) {
      setUserPrincipal(actors[0].principal);
      setUserInferenceResult(null);
    }
  }, [scenarioAdministration.inference_actors, userPrincipal]);

  useEffect(() => {
    if (activeScenarioId === "mode1b" && !MODE1B_TISSUES.includes(userTissue)) {
      setUserTissue(MODE1B_TISSUES[0]);
      setUserInferenceResult(null);
    }
  }, [activeScenarioId, userTissue]);

  return (
    <>
      <Header lastRefresh={lastRefresh} />

      <main>
        <section className="hero">
          <div>
            <span className="eyebrow">PATHMNIST · GOVERNED COLLABORATION</span>
            <h2>Federated learning with explicit admission boundaries</h2>
            <p>
              Follow training, sponsored contribution and bounded AI participation
              without collapsing identity, admission and permission into one decision.
            </p>
          </div>
          <div className="run-chip">
            <span>SELECTED MODEL RUN</span>
            <strong>
              {displayedModelRunId
                || (status.status === "running" ? "Allocating run…" : "No trained model")}
            </strong>
          </div>
        </section>

        {error ? <div className="error-banner">Hub connection: {error}</div> : null}

        <ModeSelector mode={dashboardMode} onChange={changeDashboardMode} />

        <ScenarioStrip
          activeScenarioId={activeScenarioId}
          executionStatus={status.status}
          onSelect={setSelectedScenarioId}
          mode1bUseCase={mode1bUseCase}
          onMode1bUseCaseChange={(useCase) => {
            setMode1bUseCase(useCase);
            setUserInferenceResult(null);
            setUserError("");
          }}
        />

        <Overview
          status={displayedStatus}
          participants={scenarioParticipants}
          registeredClients={scenarioRegisteredClients}
          expectedRegisteredClients={activeScenario.expectedRegisteredClients}
          activeScenario={activeScenario}
          lastRefresh={lastRefresh}
        />

        {dashboardMode === "administration" ? (
          <BoundaryControlArea
            administration={scenarioAdministration}
            busy={administrationBusy}
            ceremony={ceremony}
            error={administrationError}
            onApprove={approveKyoOrganisation}
            onBegin={beginKyoCeremony}
            onMint={mintHolderEct}
            onSelect={selectEnvelope}
          />
        ) : null}

        <nav className="tabs" aria-label="Dashboard views">
          {visibleTabs.map((tab) => (
            <button
              aria-selected={activeTab === tab}
              className={`tab ${activeTab === tab ? "active" : ""}`}
              key={tab}
              role="tab"
              type="button"
              onClick={() => setActiveTab(tab)}
            >
              {tab === "model-use" ? "Model use" : tab.charAt(0).toUpperCase() + tab.slice(1)}
            </button>
          ))}
        </nav>

        <TabPanel
          activeTab={activeTab}
          metrics={metrics}
          events={events}
          participants={scenarioParticipants}
          registeredClients={scenarioRegisteredClients}
          config={config}
          chartRounds={configEditable ? editableConfig.rounds : undefined}
          status={displayedStatus}
          editableConfig={editableConfig}
          onEditableConfigChange={handleEditableConfigChange}
          configEditable={configEditable}
          onStartExperiment={startExperiment}
          starting={starting}
          scenarioId={activeScenarioId}
          canTrain={canTrain}
          modelRunId={selectedModelRunId}
          userModePanel={(
            <UserModePanel
              administration={scenarioAdministration}
              busy={userBusy}
              error={userError}
              mode1bUseCase={mode1bUseCase}
              requesterPrincipal={requesterPrincipal}
              onRequesterChange={(principal) => {
                setRequesterPrincipal(principal);
                setUserInferenceResult(null);
                setUserError("");
              }}
              onPrincipalChange={(principal) => {
                setUserPrincipal(principal);
                setUserInferenceResult(null);
                setUserError("");
              }}
              onRunInference={runUserInference}
              onTissueChange={(tissue) => {
                setUserTissue(tissue);
                setUserInferenceResult(null);
                setUserError("");
              }}
              result={userInferenceResult}
              scenarioId={activeScenarioId}
              selectedPrincipal={userPrincipal}
              selectedTissue={userTissue}
            />
          )}
        />
      </main>

      <footer>
        <span>OpenHealth · vfp-core</span>
        <span>Mode 2 is documented as future work and is not executable here.</span>
      </footer>
    </>
  );
}
