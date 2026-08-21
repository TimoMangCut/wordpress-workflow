# Workflow Guide - Canonical Workflow (Batch 5)

Tài liệu này mô tả **workflow canonical hiện tại** của workspace này.
Mục tiêu:
- phản ánh đúng topology đã chốt ở Batch 4.5 / Batch 5
- phân biệt rõ `canonical entrypoint` với `script debug/maintenance`
- giảm nhầm lẫn giữa `force overwrite`, `reviewer_explore`, và `LLM force mode`

Nguyên tắc đọc tài liệu này:
- Đường vận hành chuẩn hằng ngày:
  - `bash tools/bin/run-single-plugin.sh <slug>`
  - nếu chỉ cần recover/debug tới hết Phase 2:
    - `bash tools/bin/run-single-plugin.sh <slug> --resume --phase2-only`
- `run-phase2.sh` và `run-phase3.sh` là **scoped rerun runners**
- `run-pipeline.sh`, `scan-all.sh`, `prepare_agent_inputs.py`, `orchestrate-agents.sh`, `write_phase2_consensus.py` là **wrapper/component scripts**, chỉ dùng khi debug, validate, batch orchestration, hoặc repair từng stage

## 1) Kiến trúc tổng quan

Pipeline gồm 3 phase:

1. Phase 1 (Deterministic Collection)
- Quét toàn bộ plugin.
- Thu tín hiệu tĩnh: surface map, Semgrep, Psalm, IR, threat context.
- Không dùng LLM.
- Psalm có cơ chế `primary + fallback` để tránh crash do `humanmade/psalm-plugin-wordpress`.

2. Phase 2 (Role-Based Review Loop + Cluster Consensus)
- deterministic prep -> worker tracing -> reviewer core -> revision -> reviewer explore -> cluster synth/challenge -> consensus
- depth policy là **adaptive by default**: workflow tự tăng độ sâu review/exploration khi tín hiệu Phase 1 mạnh hơn
- reviewer không còn là một round “đọc lại cả plugin” duy nhất
- `reviewer_core` và `reviewer_explore` là hai nhiệm vụ tách biệt
- canonical output của Phase 2 là `reports/phase2/<slug>-phase2.json`

3. Phase 3 (Gate-first + Optional LLM Skeptic)
- `phase3_gate.py` luôn chạy trước và là authoritative.
- Luôn sinh markdown deterministic.
- LLM là lớp skeptic review (theo `--llm-mode`).

Luồng canonical hiện tại:

```text
run-single-plugin.sh
  -> Phase 1
  -> threat context
  -> Phase 2 local loop
       worker
       reviewer_core
       worker revision
       reviewer_explore
  -> cluster synth/challenge
  -> consensus writer
  -> canonical phase2.json
  -> Phase 3 gate
  -> optional Phase 3 skeptic review
```

Ghi chú vận hành:
- `run-single-plugin.sh` là **single-plugin entrypoint canonical**
- `run-phase2.sh` vẫn là authority engine của Phase 2, nhưng khi vận hành thường ngày bạn có thể dùng `run-single-plugin.sh` cho cả:
  - full pipeline
  - `--resume`
  - `--phase2-only`
  - `--no-clusters` / `--clusters`

## 2) Chuẩn bị môi trường

### 2.1 Semgrep venv

Semgrep cần venv:
- `/var/www/tmmc/bin/activate`

Khuyến nghị export rõ ràng trước khi chạy:

```bash
export SEMGREP_VENV=/var/www/tmmc/bin/activate
```

Lưu ý: từ bản này, các script Semgrep chạy ở chế độ strict — nếu thiếu venv sẽ dừng ngay (không fallback sang PATH hệ thống).

### 2.2 Dependency

```bash
cd tools
composer install
cd ..
```

Lưu ý Psalm fork/pin (Plan A):
- `tools/composer.json` đã pin:
  - `vimeo/psalm: ^6.15.1`
  - `humanmade/psalm-plugin-wordpress: 3.1.2.1`
- Plugin WordPress Psalm được lấy từ path repo nội bộ:
  - `tools/forks/psalm-plugin-wordpress`
- Nếu bạn vừa pull thay đổi mới, chạy:

```bash
cd tools
composer update vimeo/psalm humanmade/psalm-plugin-wordpress --with-all-dependencies
cd ..
```

Smoke test nhanh cho fork:

```bash
php tools/bin/test-psalm-fork-smoke.php
```

### 2.3 PHP SOAP extension cho Psalm

Để tránh lỗi `Could not get class storage for soapfault`, cần bật SOAP extension trên đúng runtime PHP chạy Psalm:

```bash
php -m | grep -i soap
php -r "var_dump(class_exists('SoapFault'));"
```

Nếu chưa có:

```bash
sudo apt-get install -y php8.3-soap
```

### 2.5 PHP runtime cho Phase 1

Phase 1 hiện hỗ trợ chỉ định runtime PHP tường minh để tránh lỗi `php: command not found` khi shell không có `php` trong `PATH`.

Khuyến nghị export trước khi chạy:

```bash
export PHP_BIN=/opt/homebrew/bin/php
export PHP_MEMORY_LIMIT=1024M
```

Ghi chú:
- `PHP_BIN` có thể là đường dẫn tuyệt đối hoặc tên binary như `php8.3`
- `PHP_MEMORY_LIMIT` được dùng cho bước IR extract; **default hiện tại là 1024M** — đủ cho mọi plugin trong scope. Chỉ cần override nếu chạy trên máy rất ít RAM hoặc plugin đặc biệt lớn hơn suretriggers.

### 2.4 Quota

Trước khi chạy Phase 2/3, kiểm tra session Codex còn quota.

### 2.6 Claude Config + Multi-Provider Mode

Pipeline hiện đọc cấu hình LLM từ:

```text
.claude/settings.json
.claude/settings.local.json
```

Hai file này nằm đúng scope project của Claude Code, không nằm trong `tools/`.

- `.claude/settings.json`: policy dùng chung của repo
- `.claude/settings.local.json`: override theo máy local, ví dụ đường dẫn binary

Ví dụ cấu hình dùng chung:

```json
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "env": {
    "LLM_PROVIDERS": "codex",
    "PHASE2_WORKER_PROVIDER": "codex",
    "PHASE2_REVIEWER_PROVIDER": "codex",
    "PHASE2_PROVIDER_TIMEOUT_SECONDS": "600",
    "PHASE2_WORKER_TIMEOUT_SECONDS": "900",
    "PHASE2_REVISION_TIMEOUT_SECONDS": "600",
    "PHASE2_REVIEWER_TIMEOUT_SECONDS": "600",
    "PHASE2_EXPLORATION_TIMEOUT_SECONDS": "240",
    "PHASE2_WORKER_CLAUDE_MODEL": "claude-sonnet-4.6",
    "PHASE2_REVIEWER_CODEX_MODEL": "gpt-5.4",
    "PHASE2_REVIEWER_CLAUDE_MODEL": "claude-sonnet-4.6",
    "PHASE2_ENABLE_FORCED_EXPLORATION": "true",
    "PHASE2_MAX_EXPLORATION_CANDIDATES": "3",
    "PHASE3_PRIMARY_PROVIDER": "codex"
  }
}
```

Ví dụ local override:

```json
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "env": {
    "CLAUDE_BIN": "/opt/homebrew/bin/claude",
    "CLAUDE_MODEL": "claude-sonnet-4-6"
  }
}
```

Ý nghĩa:
- `PHASE2_WORKER_PROVIDER=codex`: Phase 2 worker mặc định là Codex.
- `PHASE2_REVIEWER_PROVIDER=codex`: reviewer mặc định của Phase 2 là Codex.
- `PHASE2_WORKER_CLAUDE_MODEL=claude-sonnet-4.6`: model worker chính cho Claude ở Phase 2.
- `PHASE2_REVIEWER_CODEX_MODEL=gpt-5.4`: model reviewer chính cho Codex ở Phase 2.
- `PHASE2_REVIEWER_CLAUDE_MODEL=claude-sonnet-4.6`: model reviewer fallback cho Claude khi cần.
- `PHASE2_PROVIDER_TIMEOUT_SECONDS=600`: fallback timeout tương thích ngược cho Phase 2 nếu timeout theo role chưa được set.
- `PHASE2_WORKER_TIMEOUT_SECONDS=900`: timeout cho worker round 1 quick/deep.
- `PHASE2_REVISION_TIMEOUT_SECONDS=600`: timeout cho worker revision/expansion rounds.
- `PHASE2_REVIEWER_TIMEOUT_SECONDS=600`: timeout cho reviewer skeptical rounds.
- `PHASE2_EXPLORATION_TIMEOUT_SECONDS=240`: timeout cho `reviewer_explore` stage.
- `PHASE2_ENABLE_FORCED_EXPLORATION=true`: tên env legacy cho `reviewer_explore`; đây không phải “force mode” tùy hứng mà là stage riêng ở cuối loop.
- `PHASE2_MAX_EXPLORATION_CANDIDATES=3`: giới hạn số candidate mới trong `reviewer_explore`.
- `LLM_PROVIDERS=codex`: mặc định Phase 3 chỉ gọi Codex trừ khi bạn override.
- `PHASE3_PRIMARY_PROVIDER`: chọn provider canonical cho Phase 3 khi chạy multi-provider.
- `CLAUDE_BIN`: cần thiết nếu shell batch không thấy `claude` trên `PATH`.
- `CLAUDE_MODEL`: model Claude mặc định cho các path không pin riêng model, ví dụ worker fallback sau này.

Có thể override tạm thời bằng CLI flag nếu cần, nhưng đây là **rerun/debug path** chứ không phải cách chạy chuẩn hằng ngày:

```bash
bash tools/bin/run-phase2.sh --slug <slug> \
  --worker-provider claude \
  --reviewer-provider codex \
  --worker-claude-model claude-sonnet-4.6 \
  --reviewer-codex-model gpt-5.4 \
  --forced-exploration \
  --max-exploration-candidates 3
bash tools/bin/run-phase3.sh --with-claude --slug <slug> --llm-mode auto
```

Ghi chú:
- Phase 2 mới là role-based loop: worker và reviewer là hai role tách biệt, không còn chọn canonical theo provider list nữa.
- Default topology hiện tại là `Codex baseline -> Claude selective contradiction`.
- Wave 6 thêm `reports/phase2/<slug>-provider-policy.json` làm artifact giải thích provider tier (`A0`..`A3`), trigger reasons, stage providers, và Phase 3 recommendation.
- `run-phase2.sh` sẽ tự resolve tier trước worker round 1 và có thể nâng tier sau `reviewer_core` nếu evidence cho thấy ambiguity/finding có giá trị cao.
- Sau `reviewer_core`, Phase 2 còn có một `reviewer_explore` stage riêng để tìm blind spots. Flag CLI vẫn mang tên legacy `forced-exploration`, nhưng về mặt workflow đây là một stage chính thức chứ không phải “force brute-search”.
- `reviewer_explore`, `cluster_challenger`, và `phase3 skeptic` là các stage duy nhất nên dùng Claude theo policy; worker broad search không còn là nơi mặc định để tiêu premium provider.
- `--with-claude` giờ được hiểu là shorthand explicit cho `--providers codex,claude`; nó không còn chỉ là hint yếu có thể bị Wave 6 policy âm thầm nuốt mất.
- `--provider` / `--providers` vẫn còn để tương thích ngược, nhưng abstraction đúng cho Phase 2 là `worker` và `reviewer`.
- Artifact canonical vẫn giữ tên cũ để không phá pipeline. Phase 2 loop artifacts được lưu sidecar theo round.
- Kiến trúc stabilization mục tiêu cho Phase 2 được chốt tại `7-workflow-wp/PHASE2-ARCHITECTURE-SPEC.md`.

## 3) Cách chạy

Phần này chỉ trả lời đúng 4 câu hỏi thực dụng:
- chạy 1 plugin thế nào
- multi-thread thế nào
- range thế nào
- kết hợp thế nào

### 3.1 Phase 1

Chạy 1 plugin:

```bash
bash tools/bin/scan-all.sh plugins/<slug>/
```

Multi-thread:

```bash
cd tools
bash bin/batch.sh ../plugins 4
cd ..
```

Range:

```bash
cd tools
bash bin/batch.sh ../plugins 1 81 100
cd ..
```

Kết hợp range + multi-thread:

```bash
cd tools
bash bin/batch.sh ../plugins 6 81 100
cd ..
```

Ghi chú:
- `batch.sh` là batch runner của Phase 1
- `4` hoặc `6` là số thread
- `81 100` là range plugin theo thứ tự index trong batch scan
- output chính của Phase 1 nằm ở `reports/phase1/`

Batch Psalm riêng (toàn bộ plugin mặc định):

```bash
bash tools/bin/run-psalm.sh
```

Batch Psalm mode custom (liệt kê index rồi nhập Start/End/Threads):

```bash
bash tools/bin/run-psalm.sh --mode custom
```

Liệt kê các output Psalm đã có:

```bash
bash tools/bin/run-psalm.sh --list-done
```

Chạy Psalm theo range + thread:

```bash
bash tools/bin/run-psalm.sh --start-index 81 --end-index 120 --threads 3
```

`run-psalm.sh` mode:
- `auto` (mặc định): chạy full range nếu không truyền `start/end`; nếu có truyền thì chạy theo range đó.
- `custom`: luôn hiển thị index list + done list rồi hỏi input Start/End/Threads.

Psalm fallback behavior (mặc định bật):
- Primary: luôn chạy `tools/config/psalm-wp.xml` (có `PsalmWordPress\\Plugin`).
- Nếu primary fail với mọi lỗi `non-timeout`, script sẽ retry theo tầng:
  - `primary+vendor`: `tools/config/psalm-wp-with-vendor.xml` (vẫn bật WP integration, mở rộng scope sang `plugin/vendor`).
  - `fallback`: `tools/config/psalm-wp-fallback.xml` (tắt WP integration).
  - `fallback+vendor`: `tools/config/psalm-wp-fallback-with-vendor.xml` (tắt WP integration + mở rộng vendor scope).
- Với dynamic hook AST không support, fork sẽ degrade thành parse error (`addParseError + return null`) thay vì ném exception làm crash.
- Fallback chỉ là chế độ degraded để giữ pipeline sống; output vẫn là `reports/phase1/<slug>-psalm.sarif`.
- Có skip list có kiểm soát cho plugin core-incompatible (`PSALM_SKIP_SLUGS`), ghi status `skip_incompatible`.
- Theo dõi fallback tại `reports/logs/<slug>-psalm.err` với các marker:
  - `primary_status=...`
  - `primary_error_class=...`
  - `primary_vendor_status=...`
  - `fallback_used=true|false`
  - `fallback_status=...`
  - `soap_class_available=true|false|php_missing`
  - `skip_incompatible=true` (nếu plugin nằm trong skip list)
  - `skip_reason=...`
  - `plugin_php_loc=...`
  - `psalm_timeout_mode=explicit|adaptive|default`
  - `psalm_timeout_effective=...`

Biến môi trường mới:

```bash
PSALM_THREADS=1
PSALM_FALLBACK=true
PSALM_FALLBACK_POLICY=all_non_timeout   # hoặc signature
PSALM_VENDOR_RETRY=true                  # retry thêm config có vendor scope
PSALM_TIMEOUT_ADAPTIVE=true              # timeout thích ứng theo LOC (mặc định true)
PSALM_SKIP_SLUGS=branda-white-labeling  # comma/space-separated
```

Timeout policy:
- Nếu set `PSALM_TIMEOUT_SECONDS`, script dùng giá trị này (override tuyệt đối).
- Nếu không set và `PSALM_TIMEOUT_ADAPTIVE=true`:
  - `< 8000 LOC` -> `180s`
  - `8000..19999 LOC` -> `300s`
  - `>= 20000 LOC` -> `480s`
- Nếu không set và `PSALM_TIMEOUT_ADAPTIVE=false`: dùng `180s`.

Tắt fallback để debug:

```bash
PSALM_FALLBACK=false bash tools/bin/scan-psalm.sh plugins/<slug>/
```

Chỉ fallback theo signature (chế độ debug):

```bash
PSALM_FALLBACK=true PSALM_FALLBACK_POLICY=signature bash tools/bin/scan-psalm.sh plugins/<slug>/
```

### 3.2 Phase 2

Chạy 1 plugin:

```bash
bash tools/bin/run-phase2.sh --slug <slug>
```

Range:

```bash
bash tools/bin/run-phase2.sh --start-index 81 --end-index 100 --threads 3
```

Multi-thread:

```bash
bash tools/bin/run-phase2.sh --start-index 81 --end-index 100 --threads 4
```

Kết hợp range + multi-thread:

```bash
bash tools/bin/run-phase2.sh --start-index 81 --end-index 100 --threads 4
```

Interactive:

```bash
bash tools/bin/run-phase2.sh --interactive
```

Ghi chú:
- Phase 2 hiện đã bao gồm:
  - worker
  - reviewer_core
  - revision
  - reviewer_explore
  - cluster synth/challenge
  - consensus
- `--force` chỉ là bỏ freshness check và ghi đè output cũ
- `--force-deep` chỉ override quick-triage fallback; bình thường workflow đã deep mặc định và tự tăng thêm độ sâu theo tín hiệu Phase 1
- `--forced-exploration` là tên flag legacy của `reviewer_explore`
- `--clusters` / `--no-clusters` chỉ bật/tắt cluster stage ở cuối Phase 2

Artifact canonical của `run-phase2.sh` hiện có 3 lớp:
- `reports/phase2/<slug>-phase2.local.json`: kết quả local loop sau worker/reviewer/revision.
- `reports/phase2/<slug>-phase2.consensus.json`: deterministic consensus sau cluster stage.
- `reports/phase2/<slug>-phase2.json`: canonical output cuối cùng cho Phase 3.

### 3.3 Phase 3

Chạy 1 plugin:

```bash
bash tools/bin/run-phase3.sh --slug <slug> --llm-mode auto
```

Range:

```bash
bash tools/bin/run-phase3.sh
```

Sau đó nhập:
- `Start index`
- `End index`

Multi-thread:

```bash
bash tools/bin/run-phase3.sh
```

Sau đó nhập:
- `Start index`
- `End index`
- `Threads`

Kết hợp range + multi-thread:

```bash
bash tools/bin/run-phase3.sh --llm-mode auto
```

Sau đó nhập:
- `Start index`
- `End index`
- `Threads`

Deterministic only:

```bash
bash tools/bin/run-phase3.sh --slug <slug> --llm-mode off
```

LLM skeptic bắt buộc:

```bash
bash tools/bin/run-phase3.sh --slug <slug> --llm-mode force
```

Artifact sidecar:
- Phase 2:
  - canonical: `reports/phase2/<slug>-phase2.json`
  - worker rounds: `reports/phase2/<slug>-phase2.worker.r<N>.json`
  - worker raw snapshots: `reports/phase2/<slug>-phase2.worker.r<N>.raw.json`
  - reviewer critiques: `reports/phase2/<slug>-phase2.review.r<N>.json`
  - legacy compatibility sidecar: `reports/phase2/<slug>-phase2.codex.json` hoặc `reports/phase2/<slug>-phase2.claude.json` tùy worker provider cuối cùng
- Phase 3b:
  - canonical review JSON: `reports/phase3/<slug>-phase3-review.json`
  - codex review JSON: `reports/phase3/<slug>-phase3-review.codex.json`
  - claude review JSON: `reports/phase3/<slug>-phase3-review.claude.json`
  - provider markdowns only: `reports/phase3/<index>-<slug>.codex.llm.md`, `reports/phase3/<index>-<slug>.claude.llm.md`

LLM mode:
- `auto`: canonical mode, chỉ gọi LLM nếu gate còn `uncertain/risk_note`.
- `off`: deterministic-only mode cho benchmark/debug.
- `force`: luôn gọi LLM skeptic sau gate. Đây là debug/validation mode, **không phải mode vận hành chuẩn**.

Apply review loop (tùy chọn):

```bash
bash tools/bin/run-phase3.sh --slug <slug> --llm-mode auto --apply-review
```

### 3.4 Full Audit

Full audit 1 plugin, đường chuẩn đơn giản nhất:

```bash
bash tools/bin/run-single-plugin.sh <slug>
bash tools/bin/run-single-plugin.sh <slug> --resume
```

Full audit nhiều plugin / batch orchestration:

```bash
bash tools/bin/run-pipeline.sh
bash tools/bin/run-pipeline.sh --multi-agent
bash tools/bin/run-pipeline.sh --multi-agent --resume
```

Lưu ý rất quan trọng:
- `run-single-plugin.sh` là **public full-audit entrypoint** cho 1 plugin
- Resume public cho full-audit 1 plugin là:
  - `bash tools/bin/run-single-plugin.sh <slug> --resume`
- `run-single-plugin.sh` luôn chạy:
  - `Phase 1`
  - `Phase 2 canonical local loop`
  - `cluster/consensus`
  - `Phase 3`
- `run-pipeline.sh` là **wrapper batch/internal orchestration**
- `run-pipeline.sh --multi-agent` giờ chỉ là wrapper ép `run-phase2.sh` chạy **chunked worker mode**; nó **không còn** gọi `orchestrate-agents.sh` như một authority Phase 2 public riêng
- Resume public cho batch/internal wrapper là:
  - `bash tools/bin/run-pipeline.sh --multi-agent --resume`
- `--resume` là public UX flag; các cờ cũ như `--resume-existing` và `--resume-missing-only` vẫn còn cho debug/internal paths nhưng không còn là UX chính

### 3.5 Script thành phần

Chỉ dùng khi debug / validate / repair từng tầng:
- `bash tools/bin/scan-all.sh plugins/<slug>/`
- `python3 tools/bin/prepare_agent_inputs.py <slug>`
- `bash tools/bin/orchestrate-agents.sh <slug>`
- `python3 tools/bin/build_candidate_clusters.py <slug>`
- `python3 tools/bin/build_cluster_evidence_pack.py <slug>`
- `python3 tools/bin/write_phase2_consensus.py <slug>`

## 4) Output và quota

Layout chuẩn của `reports/`:
- `reports/phase1` chứa toàn bộ artifact Phase 1
- `reports/phase2` chứa toàn bộ artifact Phase 2
- `reports/phase3` chứa toàn bộ artifact Phase 3
- `reports/context` chứa deterministic context dùng xuyên phase
- `reports/logs` chứa log và quota ledger
- `reports/cost` chứa summary chi phí theo từng `run_id`

Artifact prep/runtime quan trọng của Phase 2 giờ có chỗ riêng:
- `reports/context/<slug>-threat-context.json`
- `reports/phase2/prep/<slug>/dispatch.json`
- `reports/phase2/prep/<slug>/candidate-inventory.json`
- `reports/phase2/prep/<slug>/candidate-bundles/agent-wNN.input.json`
- `reports/phase2/agents/<slug>/agent-wNN.output.json`
- `reports/phase2/agents/<slug>/attempts/<agent>.attempt-XX.output.json`
- `reports/phase2/agents/<slug>/attempts/<agent>.attempt-XX.normalized.json`

Các file này không phải canonical findings output, nhưng là context/prep/runtime artifact cho Phase 2 chunked path.

Nếu chưa có thư mục, các script sẽ tự tạo trước khi ghi output.

Ledger nằm tại:
- `reports/logs/quota-ledger.jsonl`
- `reports/cost/<slug>/<run_id>.cost.json`

Log tree của chunked Phase 2:
- `reports/logs/<slug>/phase2/run.err`
- `reports/logs/<slug>/phase2/run.live.log`
- `reports/logs/<slug>/phase2/chunked/run.err`
- `reports/logs/<slug>/phase2/chunked/run.live.log`
- `reports/logs/<slug>/phase2/chunked/agents/<agent>/attempt-XX/assistant.live.log`
- `reports/logs/<slug>/phase2/chunked/agents/<agent>/attempt-XX/provider.raw.log`
- `reports/logs/<slug>/phase2/chunked/agents/<agent>/attempt-XX/stderr.err`

Xem thống kê:

```bash
python3 tools/bin/quota-report.py --reports-dir reports --phase phase2 --days 1
python3 tools/bin/quota-report.py --reports-dir reports --phase phase3 --days 1
python3 tools/bin/quota-report.py --reports-dir reports --phase all --days 7
python3 tools/bin/quota-report.py --run-id <run_id> --days 30
```

Phase 2 giờ có `trust_state` rõ ràng trong:
- `reports/phase2/<slug>-phase2.state.json`
- `reports/phase2/<slug>-phase2.local.json`
- `reports/phase2/<slug>-phase2.consensus.json`
- `reports/phase2/<slug>-phase2.json`

Giá trị chính:
- `success`
- `degraded_success`
- `partial_success`
- `failed`
- `in_progress` (chỉ ở state runtime)

Quy ước đọc:
- `phase2.local.json` = local merge, không phải downstream truth
- `phase2.json` = canonical Phase 2, chỉ hợp lệ sau consensus-authoritative publish

## 5) File output chính

### 5.1 Phase 1
- `reports/phase1/<slug>-surface.txt`
- `reports/phase1/<slug>-semgrep.json`
- `reports/phase1/<slug>-progpilot.json` (nếu có chạy)
- `reports/phase1/<slug>-psalm.sarif`
  - Có thể là SARIF chuẩn hoặc JSON status (`timeout`, `error`, `not_installed`, `skip_incompatible`).
- `reports/phase1/<slug>-ir.json`

### 5.2 Phase 2
- `reports/phase2/<slug>-phase2.state.json`
- `reports/phase2/<slug>-phase2.local.json`
- `reports/phase2/<slug>-phase2.consensus.json`
- `reports/phase2/<slug>-phase2.json`
- `reports/phase2/<slug>-phase2.loop-summary.json`
- `reports/phase2/<slug>-phase2.worker.r1.json`
- `reports/phase2/<slug>-phase2.review.r1.core.input.json` (nếu reviewer core đã build input)

Runner Phase 2 dùng freshness-aware skip:
- chỉ skip khi `phase2.json` mới hơn IR, source tree plugin, prompt/system prompt trực tiếp, và script Phase 2 liên quan
- `--force` sẽ bỏ qua freshness check

Ghi chú:
- `phase2.state.json` là source of truth cho stage/status/provider/log path khi run đang chạy
- `phase2.local.json` có thể tồn tại ngay cả khi Phase 2 cuối chưa được publish canonical
- `phase2.json` chỉ được coi là authoritative khi consensus writer hoàn tất

### 5.3 Phase 3
- `reports/phase3/<slug>-phase3.json`
- `reports/phase3/<index>-<slug>.md`
- `reports/phase3/<index>-<slug>.codex.llm.md` (mặc định nếu có LLM)
- `reports/phase3/<index>-<slug>.claude.llm.md` (chỉ khi bật Claude)
- `reports/phase3/<slug>-phase3-review.json` (nếu có)
- `reports/phase3/<slug>-phase3-review-diff.json` (nếu có)
- `reports/phase3/<slug>-phase3.gate.json` (snapshot trước khi apply review, nếu có)
- `reports/phase3/<slug>-phase3.final.json` (snapshot cuối sau apply review, nếu có)

Canonical Phase 3 selection:
- `phase3.json` luôn là gate output
- `phase3.final.json` chỉ được coi là canonical khi file này **không cũ hơn** `phase3.json`
- markdown report và benchmark comparison phải đọc Phase 3 canonical artifact theo rule trên

Runner Phase 3 cũng dùng freshness-aware skip theo từng lớp:
- gate JSON
- optional final snapshot sau apply review
- markdown deterministic report

## 6) Cách xóa hết thông tin theo từng phase

Lưu ý: luôn chạy lệnh preview trước, sau đó mới chạy lệnh xóa.

### 6.1 Xóa toàn bộ thông tin Phase 1

Preview:

```bash
find reports/phase1 -maxdepth 1 -type f \( \
  -name '*-surface.txt' -o \
  -name '*-semgrep.json' -o \
  -name '*-progpilot.json' -o \
  -name '*-psalm.sarif' -o \
  -name '*-ir.json' \
\) -print | sort

find reports/logs -maxdepth 1 -type f \( \
  -name '*.log' -o \
  -name '*-surface.*' -o \
  -name '*-semgrep.*' -o \
  -name '*-progpilot.*' -o \
  -name '*-psalm.*' -o \
  -name '*-extract.*' \
\) -print | sort
```

Xóa:

```bash
find reports/phase1 -maxdepth 1 -type f \( \
  -name '*-surface.txt' -o \
  -name '*-semgrep.json' -o \
  -name '*-progpilot.json' -o \
  -name '*-psalm.sarif' -o \
  -name '*-ir.json' \
\) -delete

find reports/logs -maxdepth 1 -type f \( \
  -name '*.log' -o \
  -name '*-surface.*' -o \
  -name '*-semgrep.*' -o \
  -name '*-progpilot.*' -o \
  -name '*-psalm.*' -o \
  -name '*-extract.*' \
\) -delete
```

Tùy chọn reset DB Phase 1:

```bash
rm -f data/audit.db
```

### 6.2 Xóa toàn bộ thông tin Phase 2

Preview:

```bash
find reports/phase2 -maxdepth 1 -type f \( \
  -name '*-phase2.json' -o \
  -name '*-phase2.raw.json' -o \
  -name '*-phase2.before_review.json' -o \
  -name '*-phase2.after_review.json' \
\) -print | sort

find reports/logs -maxdepth 1 -type f \( \
  -name '*-phase2.err' -o \
  -name '*-phase2-quick.err' \
\) -print | sort
```

Xóa:

```bash
find reports/phase2 -maxdepth 1 -type f \( \
  -name '*-phase2.json' -o \
  -name '*-phase2.raw.json' -o \
  -name '*-phase2.before_review.json' -o \
  -name '*-phase2.after_review.json' \
\) -delete

find reports/logs -maxdepth 1 -type f \( \
  -name '*-phase2.err' -o \
  -name '*-phase2-quick.err' \
\) -delete
```

### 6.3 Xóa toàn bộ thông tin Phase 3

Preview:

```bash
find reports/phase3 -maxdepth 1 -type f \( \
  -name '*-phase3.json' -o \
  -name '*-phase3.gate.json' -o \
  -name '*-phase3.final.json' -o \
  -name '*-phase3-review.json' -o \
  -name '*-phase3-review-diff.json' \
\) -print | sort

find reports/phase3 -maxdepth 1 -type f -name '*.md' -print | sort

find reports/logs -maxdepth 1 -type f -name '*-phase3.err' -print | sort
```

Xóa:

```bash
find reports/phase3 -maxdepth 1 -type f \( \
  -name '*-phase3.json' -o \
  -name '*-phase3.gate.json' -o \
  -name '*-phase3.final.json' -o \
  -name '*-phase3-review.json' -o \
  -name '*-phase3-review-diff.json' \
\) -delete

find reports/phase3 -maxdepth 1 -type f -name '*.md' -delete

find reports/logs -maxdepth 1 -type f -name '*-phase3.err' -delete
```

### 6.4 Xóa toàn bộ thông tin pipeline (Phase 1 + 2 + 3)

```bash
rm -f reports/phase1/* \
      reports/phase2/* \
      reports/phase3/*

rm -f reports/logs/*.log \
      reports/logs/*-surface.* \
      reports/logs/*-semgrep.* \
      reports/logs/*-progpilot.* \
      reports/logs/*-psalm.* \
      reports/logs/*-extract.* \
      reports/logs/*-phase2.err \
      reports/logs/*-phase2-quick.err \
      reports/logs/*-phase3.err \
      reports/logs/quota-ledger.jsonl
```

## 7) Runbook ngắn (khuyến nghị)

```bash
# 1) Full audit 1 plugin
bash tools/bin/run-single-plugin.sh <slug>
bash tools/bin/run-single-plugin.sh <slug> --resume

# 2) Phase 1 batch
cd tools && bash bin/batch.sh ../plugins 4 81 100 && cd ..

# 3) Phase 2 batch
bash tools/bin/run-phase2.sh --start-index 81 --end-index 100 --threads 3

# 4) Phase 3 batch
bash tools/bin/run-phase3.sh --llm-mode auto

# 5) Batch/internal orchestration wrapper
bash tools/bin/run-pipeline.sh --multi-agent   # wrapper ép canonical chunked Phase 2
bash tools/bin/run-pipeline.sh --multi-agent --resume

# 6) Xem quota
python3 tools/bin/quota-report.py --reports-dir reports --phase all --days 1
```

Cho case chỉ audit một plugin từ đầu đến cuối:

```bash
bash tools/bin/run-single-plugin.sh <slug>
```
