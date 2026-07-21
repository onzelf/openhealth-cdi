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

const RUN_ID = import.meta.env.VITE_RUN_ID || "local-medmnist-001";
const APP_VERSION = "v0.3.2-react-vite";
const POLL_MS = 2500;
const TABS = ["metrics", "events", "clients", "configuration", "evidence"];

async function getJson(path) {
  const response = await fetch(`/api${path}`);
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
    throw new Error(`${path} failed: ${response.status}`);
  }
  return response.json();
}

function formatMetric(rows, key) {
  const values = rows
    .map((row) => row[key])
    .filter((value) => value !== "" && value !== undefined && value !== null);

  if (!values.length) {
    return "-";
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

function isTerminalStatus(value) {
  return ["completed", "stopped", "failed"].includes(value);
}

function Overview({
  status,
  config,
  metrics,
  lastRefresh,
  editableConfig,
  onEditableConfigChange,
  configEditable,
}) {
  const totalRounds = Number(config.rounds || config.flower_rounds || 0);
  const currentRound = latestRound(metrics);
  const localEpochs = config.local_epochs || config.training?.local_epochs || "-";
  const inputDisabled = !configEditable;

  const cards = [
    ["Run ID", status.run_id || RUN_ID],
    ["Status", status.status || "-"],
    ["Dataset", config.dataset_subset || "-"],
    [
      "Registered clients",
      `${status.registered_client_count ?? "-"} / ${status.min_clients ?? "-"}`,
    ],
    ["Progress", totalRounds ? `${currentRound} / ${totalRounds}` : "-"],
    ["Last poll", lastRefresh || "-"],
    ["Latest loss", formatMetric(metrics, "loss")],
    ["Latest accuracy", formatMetric(metrics, "accuracy")],
    ["Train loss", formatMetric(metrics, "train_loss")],
    ["Train accuracy", formatMetric(metrics, "train_accuracy")],
  ];

  return (
    <section className="panel">
      <h3>Overview</h3>
      <div className="cards">
        <div className="card">
          <span>Rounds</span>
          <input
            className="card-input"
            disabled={inputDisabled}
            min="1"
            name="rounds"
            onChange={onEditableConfigChange}
            type="number"
            value={editableConfig.rounds || totalRounds || 1}
          />
        </div>
        <div className="card">
          <span>Local epochs</span>
          <input
            className="card-input"
            disabled={inputDisabled}
            min="1"
            name="local_epochs"
            onChange={onEditableConfigChange}
            type="number"
            value={editableConfig.local_epochs || localEpochs || 1}
          />
        </div>
        {cards.map(([label, value]) => (
          <div className="card" key={label}>
            <span>{label}</span>
            <strong>{value}</strong>
          </div>
        ))}
      </div>

      <div className="scope">
        This MVP demonstrates FL infrastructure and evidence capture. Governance is
        pass-through. FCaC-style admission control is not implemented.
      </div>
    </section>
  );
}

function MetricsTable({ rows }) {
  if (!rows.length) {
    return <table><tbody><tr><td>No metrics available yet.</td></tr></tbody></table>;
  }

  return (
    <table>
      <thead>
        <tr>
          <th>Round</th>
          <th>Fit clients</th>
          <th>Eval clients</th>
          <th>Loss</th>
          <th>Accuracy</th>
          <th>Train loss</th>
          <th>Train accuracy</th>
        </tr>
      </thead>
      <tbody>
        {rows.map((row, index) => (
          <tr key={`${row.round || "round"}-${index}`}>
            <td>{row.round || "-"}</td>
            <td>{row.fit_client_count || "-"}</td>
            <td>{row.eval_client_count || "-"}</td>
            <td>{row.loss || "-"}</td>
            <td>{row.accuracy || "-"}</td>
            <td>{row.train_loss || "-"}</td>
            <td>{row.train_accuracy || "-"}</td>
          </tr>
        ))}
      </tbody>
    </table>
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
              <CartesianGrid stroke="#e2e8f0" strokeDasharray="3 3" />
              <XAxis
                dataKey="round"
                label={{ value: "Round", position: "insideBottom", offset: -2 }}
                tickLine={false}
                stroke="#64748b"
              />
              <YAxis tickLine={false} stroke="#64748b" width={46} />
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
      {!hasValues ? (
        <p className="muted">No chartable values yet.</p>
      ) : null}
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
          { key: "accuracy", label: "Accuracy", color: "#1d4ed8" },
          { key: "train_accuracy", label: "Train accuracy", color: "#16a34a" },
        ]}
      />
      <MetricLineChart
        title="Loss over rounds"
        data={data}
        series={[
          { key: "loss", label: "Loss", color: "#dc2626" },
          { key: "train_loss", label: "Train loss", color: "#c026d3" },
        ]}
      />
    </div>
  );
}

function EventsTimeline({ events }) {
  if (!events.length) {
    return <p className="muted">No events available yet.</p>;
  }

  return (
    <div>
      {[...events].reverse().map((event, index) => (
        <details key={`${event.timestamp || "event"}-${index}`}>
          <summary>
            {event.event_type || "event"} - {event.component || "component"} -{" "}
            {event.timestamp || ""}
          </summary>
          <pre>{JSON.stringify(event, null, 2)}</pre>
        </details>
      ))}
    </div>
  );
}

function ClientsTable({ participants }) {
  if (!participants.length) {
    return <table><tbody><tr><td>No clients available.</td></tr></tbody></table>;
  }

  return (
    <table>
      <thead>
        <tr>
          <th>Organisation</th>
          <th>Label</th>
          <th>Partition</th>
          <th>Enabled</th>
        </tr>
      </thead>
      <tbody>
        {participants.map((client) => (
          <tr key={client.org_id}>
            <td>{client.org_id}</td>
            <td>{client.label || "-"}</td>
            <td>{client.partition ?? "-"}</td>
            <td>{String(client.enabled)}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

function EvidenceArtifacts() {
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
    <>
      <p>
        Expected artefacts under <code>runs/{RUN_ID}/</code>:
      </p>
      <ul>
        {artefacts.map((artefact) => (
          <li key={artefact}>{artefact}</li>
        ))}
      </ul>
    </>
  );
}

function TabPanel({ activeTab, metrics, events, participants, config, chartRounds }) {
  const totalRounds = Number(chartRounds || config.rounds || config.flower_rounds || 0);

  return (
    <>
      <section className={`panel ${activeTab === "metrics" ? "" : "hidden"}`}>
        <h3>Metrics</h3>
        <MetricsCharts rows={metrics} totalRounds={totalRounds} />
        <MetricsTable rows={metrics} />
      </section>

      <section className={`panel ${activeTab === "events" ? "" : "hidden"}`}>
        <h3>Event timeline</h3>
        <EventsTimeline events={events} />
      </section>

      <section className={`panel ${activeTab === "clients" ? "" : "hidden"}`}>
        <h3>Clients</h3>
        <ClientsTable participants={participants} />
      </section>

      <section className={`panel ${activeTab === "configuration" ? "" : "hidden"}`}>
        <h3>Configuration</h3>
        <pre>{JSON.stringify(config, null, 2)}</pre>
      </section>

      <section className={`panel ${activeTab === "evidence" ? "" : "hidden"}`}>
        <h3>Evidence artefacts</h3>
        <EvidenceArtifacts />
      </section>
    </>
  );
}

function Header() {
  return (
    <header>
      <div className="brand">
        <img className="logo-img" src={logoUrl} alt="OpenHealth logo" />
        <div>
          <h1>OpenHealth</h1>
          <div className="muted">VFP Federated Computing MVP</div>
        </div>
      </div>
      <div className="badges">
        <span className="badge blue">vfp-core</span>
        <span className="badge orange">vfp-governance: pass-through</span>
        <span className="badge gray">FCaC not enabled</span>
        <span className="badge green">{APP_VERSION}</span>
      </div>
    </header>
  );
}

export default function App() {
  const [activeTab, setActiveTab] = useState("metrics");
  const [status, setStatus] = useState({});
  const [experiment, setExperiment] = useState({});
  const [metrics, setMetrics] = useState([]);
  const [events, setEvents] = useState([]);
  const [lastRefresh, setLastRefresh] = useState("");
  const [error, setError] = useState("");
  const [starting, setStarting] = useState(false);
  const [editableConfig, setEditableConfig] = useState({
    rounds: 1,
    local_epochs: 1,
  });
  const pollIntervalRef = useRef(null);
  const configDirtyRef = useRef(false);

  const config = experiment.experiment_config || {};
  const configEditable = status.status === "waiting" && !starting;
  const participants = useMemo(
    () => experiment.participants?.participants || [],
    [experiment.participants]
  );

  function clearPollInterval() {
    if (pollIntervalRef.current !== null) {
      window.clearInterval(pollIntervalRef.current);
      pollIntervalRef.current = null;
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
      setMetrics(metricsPayload.metrics || []);
      setEvents(eventsPayload.events || []);
      if (!configDirtyRef.current) {
        setEditableConfig({
          rounds: experimentPayload.experiment_config?.rounds || 1,
          local_epochs: experimentPayload.experiment_config?.local_epochs || 1,
        });
      }
      setLastRefresh(new Date().toLocaleTimeString());
      setError("");

      if (isTerminalStatus(statusPayload.status)) {
        clearPollInterval();
      }
    } catch (err) {
      setStatus((current) => ({ ...current, status: "error" }));
      setError(err.message);
      console.error(err);
    }
  }

  async function startExperiment() {
    setStarting(true);
    try {
      await postJson(`/experiments/initialise`, {
        run_id: RUN_ID,
        dataset: config.dataset || "medmnist",
        dataset_subset: config.dataset_subset || "pneumoniamnist",
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

  useEffect(() => {
    refreshAll();
    pollIntervalRef.current = window.setInterval(refreshAll, POLL_MS);
    return clearPollInterval;
  }, []);

  return (
    <>
      <Header />

      <main>
        <div className="top-row">
          <div>
            <h2>Experiment dashboard</h2>
            <div className="muted">Reproducible FL infrastructure scaffold</div>
          </div>
          <div>
            <button
              id="startButton"
              type="button"
              onClick={startExperiment}
              disabled={starting || !status.can_start}
            >
              START EXPERIMENT
            </button>
          </div>
        </div>

        {error ? <div className="error-banner">{error}</div> : null}

        <Overview
          status={status}
          config={config}
          metrics={metrics}
          lastRefresh={lastRefresh}
          editableConfig={editableConfig}
          onEditableConfigChange={handleEditableConfigChange}
          configEditable={configEditable}
        />

        <div className="tabs">
          {TABS.map((tab) => (
            <button
              className={`tab ${activeTab === tab ? "active" : ""}`}
              key={tab}
              type="button"
              onClick={() => setActiveTab(tab)}
            >
              {tab === "clients" ? "Clients" : tab.charAt(0).toUpperCase() + tab.slice(1)}
            </button>
          ))}
        </div>

        <TabPanel
          activeTab={activeTab}
          metrics={metrics}
          events={events}
          participants={participants}
          config={config}
          chartRounds={configEditable ? editableConfig.rounds : undefined}
        />
      </main>
    </>
  );
}
