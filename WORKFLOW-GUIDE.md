# Workflow Guide - Enhanced Method (V2)

Tài liệu này mô tả cách vận hành pipeline enhanced trong workspace `source-code`.
Mục tiêu:
- Chạy ổn định cho batch lớn.
- Kiểm soát quota LLM.
- Tách rõ vai trò từng phase.
- Giữ output dễ đọc cho người vận hành.

## 1) Kiến trúc tổng quan

Pipeline gồm 3 phase:

1. Phase 1 (Deterministic Collection)
- Quét toàn bộ plugin.
- Thu tín hiệu tĩnh: surface map, Semgrep, Psalm, IR.
- Không dùng LLM.
- Psalm có cơ chế `primary + fallback` để tránh crash do `humanmade/psalm-plugin-wordpress`.

2. Phase 2 (LLM Analysis + Deterministic Postprocess)
- Chạy theo index range để kiểm soát quota.
- Có chế độ interactive để chọn Start/End/Threads.
- Plugin low/no-signal vẫn có `phase2-lite` (không skip im lặng).

3. Phase 3 (Gate-first + Optional LLM Skeptic)
- `phase3_gate.py` luôn chạy trước và là authoritative.
- Luôn sinh markdown deterministic.
- LLM là lớp skeptic review (theo `--llm-mode`).

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
    "PHASE2_PRIMARY_PROVIDER": "codex",
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
- `LLM_PROVIDERS=codex`: mặc định chỉ chạy Codex cho Phase 2/3.
- `PHASE2_PRIMARY_PROVIDER` / `PHASE3_PRIMARY_PROVIDER`: chọn provider nào sẽ được copy về artifact canonical để downstream tiếp tục dùng.
- `CLAUDE_BIN`: cần thiết nếu shell batch không thấy `claude` trên `PATH`.
- `CLAUDE_MODEL`: model mặc định cho Claude.

Có thể override tạm thời bằng CLI flag nếu cần:

```bash
bash tools/bin/run-phase2.sh --with-claude --slug <slug>
bash tools/bin/run-phase3.sh --with-claude --slug <slug> --llm-mode auto
```

Ghi chú:
- `--provider claude` vẫn dùng được như shorthand cho single-provider.
- `--providers codex,claude` vẫn dùng được nếu muốn override đầy đủ; `--with-claude` chỉ là shorthand dễ nhớ.
- `--model` set cùng một model cho cả hai provider; nếu cần tách riêng thì dùng `--codex-model` và `--claude-model`.
- Artifact canonical vẫn giữ tên cũ để không phá pipeline. Artifact theo provider được lưu sidecar riêng.

## 3) Cách chạy chuẩn

### 3.1 Phase 1 - toàn bộ plugin

```bash
cd tools
bash bin/batch.sh ../plugins 4
cd ..
```

Hoặc chạy một plugin:

```bash
bash tools/bin/scan-all.sh plugins/<slug>/
```

Hoặc chạy trọn pipeline 1 plugin theo thứ tự Phase 1 -> Phase 2 -> Phase 3:

```bash
bash tools/bin/run-single-plugin.sh <slug>
```

Wrapper này:
- chỉ dành cho một plugin mỗi lần chạy
- mặc định chỉ gọi Codex
- chỉ khi thêm `--with-claude` mới chạy thêm Claude
- dừng lại nếu Phase 1 không sinh `reports/phase1/<slug>-ir.json` hoặc Phase 2 không sinh `reports/phase2/<slug>-phase2.json`

Ví dụ chạy theo path plugin:

```bash
bash tools/bin/run-single-plugin.sh plugins/<slug>
```

Ví dụ bật thêm Claude:

```bash
bash tools/bin/run-single-plugin.sh <slug> --with-claude --llm-mode auto
```

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

### 3.2 Phase 2 - chạy theo range (khuyến nghị)

Chế độ interactive:

```bash
bash tools/bin/run-phase2.sh --interactive
```

Script sẽ:
1. Hiển thị index theo IR-order.
2. Hiển thị index đã có output Phase 2.
3. Hỏi Start index.
4. Hỏi End index.
5. Hỏi Threads.

Chế độ non-interactive:

```bash
bash tools/bin/run-phase2.sh --start-index 81 --end-index 100 --threads 3
```

Chạy một plugin:

```bash
bash tools/bin/run-phase2.sh --slug <slug>
```

Ví dụ ép chạy cả Codex lẫn Claude bằng CLI:

```bash
bash tools/bin/run-phase2.sh --with-claude --slug <slug>
```

Option quan trọng:
- `--force`: ghi đè output Phase 2 cũ.
- `--force-deep`: luôn deep prompt, bỏ quick triage.

### 3.3 Phase 3 - gate-first + LLM mode

Chế độ interactive:

```bash
bash tools/bin/run-phase3.sh --llm-mode auto
```

Chạy một plugin:

```bash
bash tools/bin/run-phase3.sh --slug <slug> --llm-mode auto
```

Ví dụ ép chạy cả Codex lẫn Claude bằng CLI:

```bash
bash tools/bin/run-phase3.sh --with-claude --slug <slug> --llm-mode auto
```

Artifact sidecar khi chạy multi-provider:
- Phase 2:
  - canonical: `reports/phase2/<slug>-phase2.json`
  - codex: `reports/phase2/<slug>-phase2.codex.json`
  - claude: `reports/phase2/<slug>-phase2.claude.json`
- Phase 3b:
  - canonical review JSON: `reports/phase3/<slug>-phase3-review.json`
  - codex review JSON: `reports/phase3/<slug>-phase3-review.codex.json`
  - claude review JSON: `reports/phase3/<slug>-phase3-review.claude.json`
  - provider markdowns only: `reports/phase3/<index>-<slug>.codex.llm.md`, `reports/phase3/<index>-<slug>.claude.llm.md`

LLM mode:
- `auto`: chỉ gọi LLM nếu gate còn `plausible/uncertain`.
- `off`: không gọi LLM.
- `force`: luôn gọi LLM skeptic.

Apply review loop (tùy chọn):

```bash
bash tools/bin/run-phase3.sh --slug <slug> --llm-mode auto --apply-review
```

## 4) Quota dashboard

Layout chuẩn của `reports/`:
- `reports/phase1` chứa toàn bộ artifact Phase 1
- `reports/phase2` chứa toàn bộ artifact Phase 2
- `reports/phase3` chứa toàn bộ artifact Phase 3
- `reports/logs` chứa log và quota ledger

Nếu chưa có thư mục, các script sẽ tự tạo trước khi ghi output.

Ledger nằm tại:
- `reports/logs/quota-ledger.jsonl`

Xem thống kê:

```bash
python3 tools/bin/quota-report.py --reports-dir reports --phase phase2 --days 1
python3 tools/bin/quota-report.py --reports-dir reports --phase phase3 --days 1
python3 tools/bin/quota-report.py --reports-dir reports --phase all --days 7
```

## 5) File output chính

### 5.1 Phase 1
- `reports/phase1/<slug>-surface.txt`
- `reports/phase1/<slug>-semgrep.json`
- `reports/phase1/<slug>-progpilot.json` (nếu có chạy)
- `reports/phase1/<slug>-psalm.sarif`
  - Có thể là SARIF chuẩn hoặc JSON status (`timeout`, `error`, `not_installed`, `skip_incompatible`).
- `reports/phase1/<slug>-ir.json`

### 5.2 Phase 2
- `reports/phase2/<slug>-phase2.raw.json`
- `reports/phase2/<slug>-phase2.json`
- `reports/phase2/<slug>-phase2.before_review.json` (nếu apply review)
- `reports/phase2/<slug>-phase2.after_review.json` (nếu apply review)

### 5.3 Phase 3
- `reports/phase3/<slug>-phase3.json`
- `reports/phase3/<index>-<slug>.md`
- `reports/phase3/<index>-<slug>.codex.llm.md` (mặc định nếu có LLM)
- `reports/phase3/<index>-<slug>.claude.llm.md` (chỉ khi bật Claude)
- `reports/phase3/<slug>-phase3-review.json` (nếu có)
- `reports/phase3/<slug>-phase3-review-diff.json` (nếu có)
- `reports/phase3/<slug>-phase3.gate.json` (snapshot trước khi apply review, nếu có)
- `reports/phase3/<slug>-phase3.final.json` (snapshot cuối sau apply review, nếu có)

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
# 1) Phase 1 toàn bộ
cd tools && bash bin/batch.sh ../plugins 4 && cd ..

# 2) Phase 2 interactive
bash tools/bin/run-phase2.sh --interactive

# 3) Phase 3 interactive + auto LLM
bash tools/bin/run-phase3.sh --llm-mode auto

# 4) Xem quota
python3 tools/bin/quota-report.py --reports-dir reports --phase all --days 1
```

Cho case chỉ audit một plugin từ đầu đến cuối:

```bash
bash tools/bin/run-single-plugin.sh <slug>
```
