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

Một Model làm toàn bộ review trong một session — không sub-agent, không pipeline. Thứ tự bắt buộc: tự parse trước, rồi chạy công cụ bắt buộc, rồi đối chiếu, rồi adjudicate.

1. **Tự parse (không công cụ):** đọc source và tự dựng IR/AST/SAST bằng chính suy luận của mình — surfaces, registration, resolved callback, data-flow, sink, persistence, trust boundary. Seal source-derived coverage ledger và hàng đợi hypothesis hữu hạn.
2. **Công cụ bắt buộc:** chỉ sau đó mới chạy `inventory` + `ast` (hỗ trợ coverage bắt buộc) và `semgrep`/`psalm` bổ trợ qua `tools/bin/wp-audit-tools.sh`. Semgrep chỉ Community (chưa cấp Pro key).
3. **Đối chiếu:** so cái tự parse với output công cụ; mở lại mọi surface parser-only/source-only, parse gap, dynamic edge chưa giải quyết trong source. Nghĩa vụ còn mở thì chặn hoàn tất.
4. **Trace & phản chứng:** trace registration → attacker control → transform/storage → defense → sensitive operation → impact, mỗi hypothesis trưởng thành có ít nhất một phản chứng cụ thể.
5. **Adjudicate:** tự gán `CONFIRMED`, `UNCERTAIN`, `RISK_NOTE` hoặc `REJECTED`; mở lại evidence, kiểm tra `path:line` và reconcile coverage trước khi báo cáo.

Không dùng Phase 1/2/3, Worker/Reviewer loop, cluster consensus, sub-agent delegation hoặc scanner severity làm authority. `inventory`/`ast` là hỗ trợ bắt buộc; `semgrep`/`psalm` là bổ trợ tùy chọn trả lời một câu hỏi cụ thể đã ghi. Không công cụ nào là verdict authority.

Sau source-led discovery, chỉ đọc `../../../docs/wordpress-pattern-catalogue.md` để late recall. Chỉ đọc `../../../docs/reportability-policy.md` và policy chính thức có ngày xác minh sau khi technical verdict ổn định và user yêu cầu reportability.

Machine-readable output theo `../../../contracts/methodology-review.schema.json`. Mỗi kết luận trưởng thành phải có `path:line`, attacker prerequisites, defense, refutation result, impact và assumptions.
