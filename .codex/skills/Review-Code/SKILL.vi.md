---
name: wp-security-audit
description:
  Phương pháp audit bảo mật WordPress plugin/theme cho SAST và phân tích đa phase.
  Dùng cho audit, triage exploitability, đánh giá Patchstack scope, và xác thực bằng chứng.
---

# WP Security Audit Skill (Bản Tiếng Việt)

## Phiên bản ngôn ngữ

- Bản active (English): `SKILL.md`
- Bản tiếng Việt: `SKILL.vi.md`

Khi skill này được kích hoạt, cần đọc thêm:

- `references/wp-context.md`
- `references/patchstack-rules.md`

## 1) Phương pháp cốt lõi

Làm theo thứ tự:

1. Lập bản đồ attack surface (entry points, auth, guards, sources, sinks)
2. Trace source -> sink kèm evidence file:line
3. Kiểm tra defense (nonce/capability/sanitizer/prepare/ownership)
4. Refute-first
5. Đánh giá exploitability và impact thực tế
6. Áp dụng Patchstack scope filter

## 2) Bao phủ entry point

Luôn cover:

- REST routes: `register_rest_route`, `permission_callback`, ownership checks
- AJAX hooks: `wp_ajax_*`, `wp_ajax_nopriv_*`
- `admin_post_*`
- Shortcode và block `render_callback`
- Import/export handlers
- Webhook/cron handlers có thể bị user tác động

## 3) Quy tắc source và sink

### Sources

- `$_GET`, `$_POST`, `$_REQUEST`, `$_COOKIE`, `$_FILES`
- REST params/body/json (`get_param`, `get_json_params`, ...)
- Attributes từ shortcode/block
- Stored values có nguồn gốc tainted (`get_option`, `get_post_meta`, ...)

### Sinks

- SQL (`$wpdb->query/get_results/get_var/get_row/get_col`)
- Output HTML/attribute/URL
- File read/write/include
- `include`/`require`
- Redirects
- Deserialization (`unserialize`, `maybe_unserialize`)
- Outbound HTTP (`wp_remote_*`)

## 4) Lưu ý quan trọng theo WordPress

- `is_admin()` không phải role/capability check.
- `admin_init` vẫn có thể reachable bởi user role thấp.
- REST JSON body không qua `wp_magic_quotes()`.
- `check_ajax_referer(..., false)` không tự động dừng execution.
- `wp_redirect()` thường cần `exit;` để tránh fall-through.

## 5) Quality gates cho finding

Chỉ giữ finding khi:

- Trace source->sink đầy đủ, verify được
- Impact bảo mật có thể đo lường
- Điều kiện và role tối thiểu được nói rõ
- Đã thử refute nhưng không bác bỏ được

Nếu bằng chứng chưa đủ:

- Đánh dấu `REVIEW` hoặc `Needs Dynamic Verification`
- Không force `TP`

## 6) Kỷ luật Patchstack scope

Reject hoặc out-of-scope khi phù hợp:

- Admin-only, impact không đáng kể
- Severity rất thấp, không exploitable
- Captcha bypass / CSV injection / race condition mức thấp ngoài ngưỡng

## 7) Căn chỉnh theo phase

### Phase 2

- Validate và normalize `phase2.json` theo evidence-bound schema.
- Giữ ambiguity ở trạng thái `REVIEW`.

### Phase 3

- Deterministic gate là authoritative.
- LLM chỉ skeptic review với `PLAUSIBLE/UNCERTAIN`.

## 8) Kỷ luật output

- Không output TODO list
- Không kết luận chung chung
- Mỗi kết luận phải có bằng chứng code cụ thể
