# JMIR paper reproducibility

Run all commands from the repository root.

## Table 6

Generate `JMIR_paper/table6/table6_results.csv` from the two publication-run metric files.

    python3 -c 'import csv,json; from pathlib import Path; r=Path("JMIR_paper/table6"); ab=json.load(open(r/"local-pathmnist-ab-001_metrics.json"))["metrics"]; abc=json.load(open(r/"local-pathmnist-ab-002_metrics.json"))["metrics"]; rows=[("Cancer-related macro recall","cancer_recall"),("Non-cancer macro recall","non_cancer_recall"),("Cancer-associated stroma recall","class_7_recall"),("Colorectal adenocarcinoma epithelium recall","class_8_recall"),("Global macro recall","macro_recall"),("Overall accuracy","accuracy")]; f=open(r/"table6_results.csv","w",newline=""); w=csv.writer(f); w.writerow(["metric","A+B control","A+B+C","change_pp"]); [w.writerow([label,f"{100*ab[k]:.1f}",f"{100*abc[k]:.1f}",f"{100*(abc[k]-ab[k]):.1f}"]) for label,k in rows]; f.close()'

## Table 7
Set `EID` to an active governance envelope.

    EID="PUT-ACTIVE-ENVELOPE-ID-HERE"


Generate the Table 7 decision-plane evidence.

    set -o pipefail
    ./src/tests/Test5D_mode1b_table7_conformance.sh "$EID"  2>&1 | tee JMIR_paper/table7/Test5D_mode1b_conformance.txt

Table 7 row 4 composition evidence is provided by `src/tests/Test5E_mode1b_contextual_agent.sh`.

## Table 8

Set `EID` to an active governance envelope.

    EID="PUT-ACTIVE-ENVELOPE-ID-HERE"

Generate the three benchmark datasets.

    BENCH_CASE=allow NITER=1000 ./src/tests/microbench/Bench_admission_pathmnist.sh "$EID"
    BENCH_CASE=deny_scope NITER=1000 ./src/tests/microbench/Bench_admission_pathmnist.sh "$EID"
    BENCH_CASE=deny_pop NITER=1000 ./src/tests/microbench/Bench_admission_pathmnist.sh "$EID"

Copy the generated samples into the paper evidence directory.

    cp src/tests/microbench/admission_bench_allow.jsonl JMIR_paper/table8/
    cp src/tests/microbench/admission_bench_deny_scope.jsonl JMIR_paper/table8/
    cp src/tests/microbench/admission_bench_deny_pop.jsonl JMIR_paper/table8/

Compute the p50 summaries.

    ./src/tests/microbench/compute_p50.sh JMIR_paper/table8/admission_bench_allow.jsonl
    ./src/tests/microbench/compute_p50.sh JMIR_paper/table8/admission_bench_deny_scope.jsonl
    ./src/tests/microbench/compute_p50.sh JMIR_paper/table8/admission_bench_deny_pop.jsonl
