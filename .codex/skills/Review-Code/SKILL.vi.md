---
name: wp-security-audit
description: Phương pháp review source-first cho WordPress plugin với tracing, refutation, verdict thống nhất, công cụ on-demand và bounty triage sau technical verdict.
---

# WordPress Security Audit — Bản tương thích tiếng Việt

Bản active là `SKILL.md`. Context canonical dùng chung với Kiro:

- `../../../docs/wp-context.md`
- `../../../docs/review-methodology.md`
- `../../../AGENTS.md`

Không load scanner output, phase artifacts, pattern catalogue, bounty rules hoặc context archive trong vòng khám phá đầu tiên.

## Workflow

1. Hiểu chức năng, kiến trúc, tài sản và trust boundary từ source.
2. Lập coverage ledger và source-led surface map.
3. Tạo hypothesis hữu hạn rồi trace registration → attacker control → transform/storage → defense → sensitive operation → impact.
4. Thử ít nhất một phản chứng cụ thể cho mỗi hypothesis trưởng thành.
5. Adjudicate trực tiếp bằng `CONFIRMED`, `UNCERTAIN`, `RISK_NOTE` hoặc `REJECTED`.
6. Mở lại evidence, kiểm tra `path:line` và reconcile coverage trước khi báo cáo.

Không dùng Phase 1/2/3, Worker/Reviewer loop, cluster consensus hoặc scanner severity làm authority. Công cụ chỉ được gọi để trả lời một câu hỏi cụ thể sau khi đã ghi static evidence gap.

Sau source-led discovery, chỉ đọc `../../../docs/wordpress-pattern-catalogue.md` để late recall. Chỉ đọc `../../../docs/reportability-policy.md` và policy chính thức có ngày xác minh sau khi technical verdict ổn định và user yêu cầu reportability.

Machine-readable output theo `../../../contracts/methodology-review.schema.json`. Mỗi kết luận trưởng thành phải có `path:line`, attacker prerequisites, defense, refutation result, impact và assumptions.
