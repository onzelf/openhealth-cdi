# Frontend to hub contract

The calls a page makes to the hub, from `src/vfp-core/frontend/src/App.jsx` and
`src/vfp-core/hub/hub.py`. The page shows state and sends requests; the hub, gatekeeper and
issuers make every decision.

## Reaching the hub

- Call `/api/<path>`; nginx forwards it to the hub as `<path>`.
- No authentication and no CORS headers, so a page must sit behind a same-origin `/api/` proxy.
- The hub is private until L1-C, so pages built elsewhere should mock these calls.
- Every success is a JSON body, so a mock must return one (`{}` is enough).

## Read calls

The dashboard re-reads these every 2.5 s so training progress stays live. A page can read them as
often or as rarely as it needs.

- `GET /experiments/{run_id}/status`: includes `status`, `active_envelope_id`, `backend_bound`,
  `registered_clients`, `registered_client_count`, `min_clients`, `model_run_id`, `can_start`.
- `GET /experiments/{run_id}`: `experiment_config` and `participants.participants[]`.
- `GET /experiments/{run_id}/metrics`: `model_run_id` and `metrics[]` (`round`, `accuracy`,
  `train_accuracy`, `loss`, `train_loss`, as strings).
- `GET /experiments/{run_id}/events?limit=150`: `events[]` (`timestamp`, `event_type`, ...).
- `GET /administration/boundary`: `envelopes[]`, `holders[]` (`ect_status`, `can_mint`,
  `modes`), `inference_actors[]`, `selected_envelope_id`. Slow; poll it only when needed.

Values: `status` is `waiting`, `running`, `completed` or `stopped`. `ect_status` is `missing`,
`ready`, `expired` or `unavailable`. `/status` and `/start` return 404 for any run id other than
the hub's current one.

## Write calls

- `POST /administration/kyo/binds`: no body. Returns `bind_id`, `policy_hash`.
- `POST /administration/kyo/{hospital-a|hospital-b}/approve`: `bind_id`, `code` (six digits).
  Returns `organization`, `admin_cn`, and `approval.envelope_id` on the final approval only.
- `POST /administration/envelopes/{envelope_id}/select`: no body.
- `POST /administration/holders/{principal}/mint-ect`: `envelope_id` (the selected one).
- `POST /experiments/initialise`: `run_id`, `dataset`, `dataset_subset`, `phase`
  (`AB_BASE` or `MODE1A`), `rounds`, `min_clients`, `local_epochs`.
- `POST /experiments/{run_id}/start`: no body.
- `POST /user/inference`: `principal`, `envelope_id`, `requested_tissue`, `topk`. Returns
  `admission` (`allow`, `reason`, `decision_id`), `executed`, `model_run_id`, `prediction`.
- `POST /mode1b/inference`: same, for Hal only.
- `POST /mode1b/agent/request`: `requester`, `envelope_id`, `requested_tissue`, `topk`,
  optionally `run_id`; any other field is rejected (422). The response depends on
  `agent_decision.action`: `refuse`, `no_transform`, `blur_image` or `minimal_statistics`.

## Order

1. Ceremony: `kyo/binds`, then approve for hospital A and B with each issuer's code. The hub then
   binds the envelope by itself.
2. Mint an ECT for each holder who will ask anything.
3. `initialise`, wait for `can_start`, then `start`.
4. Inference, once the holder's ECT is `ready`.

## Errors

The body is `{"detail": ...}`: a string for 400, 403, 404, 409 and 502, a list for 422. 404 means
a run id mismatch, 409 a precondition not met (re-read status and show the detail), 400 bad input,
422 a page bug, 502 a service unreachable.

## What the dashboard still decides itself

1. The run id is a build-time constant (`VITE_RUN_ID`), never read from the hub.
2. The scenarios and the training `phase` are hard-coded in the page.
3. The ALLOW label is inferred from two status fields, not read as a decision.
4. The start button recomputes `can_start` instead of reading it.
5. Identity is a name the user picks, sent in the body. No login or token; L1-C needs one.
6. The tissue list and the hospital ids are hard-coded; the hub has `/predictions/ab/options`.
