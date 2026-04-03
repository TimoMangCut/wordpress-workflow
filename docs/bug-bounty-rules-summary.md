# Tóm tắt Bug Bounty Rules - Patchstack & Wordfence

> Tài liệu này được viết lại theo bố cục gần giống file mẫu đính kèm, nhưng đã rút gọn để tập trung vào **quy tắc cốt lõi**, đặc biệt là **in-scope / out-of-scope**, điều kiện hợp lệ của report, tính duy nhất, và các lý do thường bị từ chối.
>
> Nguồn tham chiếu:
> - Patchstack: https://patchstack.com/articles/bug-bounty-guidelines-rules/
> - Wordfence: https://www.wordfence.com/threat-intel/bug-bounty-program/#scope

---

## Table of Contents
- Introduction
- Patchstack
  - Reporting Protocol
  - Scope
  - Uniqueness Requirement
  - Quality Assurance
  - Rejection Criteria
  - Disclosure / CVE
- Wordfence
  - Program Overview
  - In-Scope Assets
  - Out-of-Scope Assets
  - Explicitly In-Scope Vulnerabilities
  - Explicitly Out-of-Scope Vulnerabilities
  - Submission Rules & Key Notes
- Quick Comparison

---

# Introduction

Tài liệu này tổng hợp hai chương trình bug bounty trong hệ sinh thái WordPress:

1. **Patchstack Bug Bounty Program**
2. **Wordfence Intelligence Bug Bounty Program**

Mục tiêu của bản tóm tắt là giúp nhanh chóng xác định:
- Report nào có khả năng **được chấp nhận**
- Thành phần nào **in scope / out of scope**
- Điều kiện nào khiến report **không đủ bounty** hoặc chỉ được **CVE / disclosure**
- Những yêu cầu tối thiểu để report được xem là **valid**

---

# Patchstack

## Reporting Protocol

### Kênh gửi report
- Chỉ chấp nhận report qua form chính thức: `https://patchstack.com/database/report`
- Không chấp nhận qua email hoặc kênh khác.

### Tài khoản & tư cách tham gia
- Tài khoản researcher được tạo sau khi có ít nhất một report hợp lệ và in-scope.
- Mỗi researcher chỉ được dùng **một account**.
- Cá nhân và công ty đều có thể tham gia, nhưng **không hỗ trợ team submissions**.

---

## Scope

### In scope
Patchstack chấp nhận các thành phần trong hệ sinh thái WordPress, bao gồm:
- **WordPress core**
- **WordPress plugins**
- **WordPress themes**

Cả **free** và **premium** đều có thể được chấp nhận.
- Với sản phẩm premium, cần cung cấp **bản archive gốc, không chỉnh sửa** để xác minh.
- Nếu theme phụ thuộc plugin cụ thể, cần cung cấp cả plugin phụ thuộc đó.

Một report chỉ được coi là hợp lệ nếu có **security impact rõ ràng và đo lường được**.

### Out of scope / không được chấp nhận
Các trường hợp sau thường bị loại:

#### 1) Severity / CVSS quá thấp
- Vulnerability có **CVSS v3.1 < 6.5** không được chấp nhận trực tiếp theo rules hiện tại.

#### 2) Active installs quá thấp
- Component có **< 1,000 active installs** nhìn chung là out of scope.
- Ngoại lệ: có thể được xem xét nếu:
  - có **CVSS >= 8.5**,
  - yêu cầu quyền không vượt quá **Unauthenticated / Subscriber / Customer**,
  - và component có **ít nhất 100 active installs**.

#### 3) Quyền khai thác quá cao
- Chỉ ưu tiên lỗ hổng khai thác được bởi:
  - **Unauthenticated**
  - **Subscriber / Customer**
- **Contributor** chỉ được chấp nhận nếu severity đủ cao.
- Các lỗ hổng yêu cầu **Admin / quyền cao hơn** là out of scope.
- Với **custom roles**, chỉ chấp nhận nếu capability tương đương gần với Subscriber/Customer; nếu mạnh hơn thì không chấp nhận.

#### 4) Các loại issue thường không được chấp nhận
- **CSV Injection**
- **IP spoofing** (trừ khi trực tiếp phá vỡ một cơ chế bảo vệ phụ thuộc vào IP)
- **Race condition** có tác động không rõ ràng hoặc severity thấp
- **CAPTCHA / Turing test bypass**
- **Arbitrary user registration** nếu không dẫn đến tạo được **admin account**
- **Authenticated shortcode preview issues** ở mức Contributor trở lên, trừ khi lộ dữ liệu nhạy cảm có tác động rõ ràng
- **CSRF / Broken Access Control** chỉ dùng để dismiss notice mà không có security impact thực tế
- **IP bypass** cho các thao tác không quan trọng như likes/views/counters

#### 5) Thành phần không đủ điều kiện
- Phiên bản cuối cùng phát hành đã quá **3 năm**
- Lỗ hổng **không còn tồn tại ở phiên bản mới nhất**
- Component **không public**
- Component là hàng **custom / modified / private**, không được phân phối công khai qua:
  - WordPress.org
  - website chính thức của vendor
  - GitHub
  - CodeCanyon / ThemeForest
  - hoặc nguồn public tương đương

---

## Uniqueness Requirement

- Report phải là **mới**, **unique**, chưa từng được public hoặc báo trước đó.
- Nếu nhiều người báo cùng một issue, **người gửi valid report đầu tiên** sẽ được tính.
- Nếu issue đã được báo trực tiếp cho vendor trước đó, Patchstack chỉ chấp nhận nếu:
  - vendor xác nhận issue,
  - và vendor có ý định vá.
- Với sản phẩm của **Automattic**, phải report qua **HackerOne của Automattic** trước.
- Incomplete patch đã public thường **không được xem là issue mới**, trừ khi tạo ra attack vector mới.

---

## Quality Assurance

Một report Patchstack cần có tối thiểu:
- PoC dạng text, từng bước rõ ràng
- Các bước từ lúc cài plugin/theme cho đến khi exploit thành công
- Raw HTTP request cần thiết
- Payload chính xác đã dùng
- Video screenshot là điểm cộng

### Rủi ro khi gửi report kém chất lượng
- Report không đầy đủ, không tái hiện được, hoặc sai sẽ bị reject.
- Gửi lặp lại false positive / AI-generated false positive có thể dẫn tới:
  - cooldown,
  - bị khóa dashboard tạm thời,
  - hoặc khóa vĩnh viễn.

---

## Rejection Criteria

Các lý do reject phổ biến:
- Thông tin không đầy đủ hoặc không chính xác
- Claim không phải vulnerability hợp lệ
- Dùng role không chuẩn / role đã chỉnh sửa
- Plugin/theme đã đóng hoặc không truy cập được
- Component không được phân phối công khai qua nguồn đáng tin cậy
- Developer/vendor gửi issue cho chính sản phẩm của họ: có thể dùng cho disclosure nhưng **không đủ điều kiện bounty**

---

## Disclosure / CVE

- Patchstack là **CNA**, nên issue hợp lệ có thể được cấp **CVE**.
- Việc cấp CVE có thể bị trì hoãn để tránh trùng với CNA khác.
- Tất cả valid in-scope reports sẽ được đưa vào **Patchstack Vulnerability Database**.
- Researcher không được public vulnerability cho bên thứ ba trước khi Patchstack công bố chính thức.

---

# Wordfence

## Program Overview

Wordfence tập trung vào bug bounty cho **WordPress plugins và themes**. Chương trình phân scope khá mạnh dựa trên:
- loại vulnerability,
- mức quyền yêu cầu,
- active installs,
- và **researcher tier**.

Wordfence cũng có thể cấp **CVE** cho cả một số report out of scope, nhưng **không phải report nào cũng đủ điều kiện nhận bounty**.

---

## In-Scope Assets

### Nhóm 1: High Threat Vulnerabilities
Tất cả plugin/theme WordPress (free và premium), trừ các asset bị liệt kê out of scope, sẽ in scope nếu có:
- **>= 25 active installs**
- khai thác được bởi **unauthenticated** hoặc **low-level authenticated** (Subscriber/Customer)
- thuộc một trong các loại sau:
  - Arbitrary PHP File Upload or Read
  - Arbitrary PHP File Deletion
  - Arbitrary Options Update
  - Remote Code Execution
  - Authentication Bypass to Admin
  - Privilege Escalation to Admin

Ghi chú:
- Nếu plugin/theme có từ **25 đến 999 installs**, nó phải có trên **WordPress.org Plugin Repository** mới được tính in scope.

### Nhóm 2: Common and Dangerous Vulnerabilities
Tất cả plugin/theme WordPress (free và premium), trừ asset out of scope, sẽ in scope nếu có:
- **>= 500 active installs**
- khai thác được bởi **unauthenticated** hoặc **Subscriber/Customer**
- thuộc một trong các loại:
  - **Stored XSS**
  - **SQL Injection**

Ghi chú:
- Với mốc **500 đến 999 installs**, component phải có trên **WordPress.org Plugin Repository**.
- **Premium plugin/theme** bị loại khỏi nhóm này nếu **< 1,000 installs**.

### Nhóm 3: All Other Vulnerabilities
Các vulnerability khác có thể in scope, nhưng phụ thuộc vào **researcher tier**:
- **Standard Researchers**: component cần **>= 50,000 installs**
- **Resourceful Researchers**: component cần **>= 10,000 installs**
- **1337 Researchers**: component cần **>= 500 installs**

---

## Out-of-Scope Assets

Các asset sau bị loại khỏi bounty scope của Wordfence:
- **WordPress Core**
- **Tất cả sản phẩm của Automattic**
- **Tất cả sản phẩm của Facebook**
- **Tất cả sản phẩm của Google**
- **Tất cả sản phẩm của SiteGround**
- **Tất cả sản phẩm của Yoast**

Ngoài ra cũng out of scope:
- Plugin hoặc theme đã **closed to downloads / sales** tại thời điểm gửi report
- Bất kỳ **web service bên ngoài** nào đi kèm plugin/theme nhưng **không chạy local** trên site WordPress (ví dụ API trên server của vendor)

Lưu ý:
- Một số issue ở các asset trên vẫn có thể được **gán CVE**, nhưng **không nhận bounty**.

---

## Explicitly In-Scope Vulnerabilities

Wordfence chấp nhận các issue có ảnh hưởng đáng kể đến **confidentiality, integrity, availability** của website WordPress, miễn là **không yêu cầu quyền cao** như Admin/Editor để exploit.

Các loại thường được chấp nhận gồm:
- Stored XSS
- Reflected XSS
- CSRF có security impact đáng kể
- Missing Authorization có impact đáng kể
- Arbitrary Content Deletion
- SQL Injection
- Insecure Direct Object Reference (IDOR)
- Arbitrary File Upload
- Arbitrary File Download/Read
- Arbitrary File Deletion
- LFI / RFI
- Directory Traversal
- Privilege Escalation to Admin
- Privilege Escalation to Non-Admin
- Authentication Bypass to Admin
- Authentication Bypass to Non-Admin
- Remote Code Execution / Code Injection
- Information Disclosure
- SSRF
- PHP Object Injection
- Intentional Backdoors do developer thêm vào mà threat actors có thể truy cập

---

## Explicitly Out-of-Scope Vulnerabilities

Wordfence coi các issue dưới đây là out of scope hoặc rất dễ bị reject:

### 1) Impact thấp / khó khai thác ngoài thực tế
- Các issue nằm trong danh sách **Common False Positive Reports**
- **DoS** không có impact rõ ràng và đáng kể
- Dependency vulnerable nhưng **không chứng minh được exploit thực tế trong plugin/theme**
- **Open Redirect**
- **Cache Poisoning** không có impact rõ ràng
- Race condition không dễ tái hiện trong cấu hình phổ biến

### 2) Privilege quá cao
- Bất kỳ issue nào yêu cầu **PR:H**
- Bao gồm các role như:
  - **Administrator**
  - **Editor**
  - **Shop Manager**
  - hoặc role có capability `unfiltered_html`

### 3) Các issue thường bị xem là false positive / low value
- CSV Injection
- CSS Injection
- HTML Injection
- Self-XSS
- Reflected XSS qua headers
- XSS qua SVG uploads
- Payload nhúng trong file an toàn như PDF/JPG nhưng không dẫn tới site compromise
- Double extension upload kiểu `.php.png`
- Safe file type upload nếu đó là chức năng hợp lệ
- IP Spoofing
- CAPTCHA bypass
- CORS issues
- Tabnabbing
- TOCTOU
- Registration bypass nếu registration vốn được bật hợp lệ và không dẫn đến privilege escalation
- Unlimited voting/liking/counting issues
- 2FA bypass trong các tình huống không tạo security impact đáng kể
- Missing authorization nhưng không có hậu quả rõ ràng lên CIA

### 4) Phụ thuộc môi trường / cấu hình bất thường
- Chỉ khai thác được trên phần mềm **EOL**
- SQLi chỉ xảy ra nếu phải tắt `wp_magic_quotes`
- Cần local server access
- Cần cấu hình PHP không an toàn như `allow_url_fopen`
- Secret lưu plain text nhưng không exploit được qua issue khác
- File upload vào thư mục public nhưng không dẫn đến site compromise
- Thông tin lộ ra chỉ khi bật `WP_DEBUG`
- Lỗ hổng chỉ xảy ra do admin misconfigure hệ thống
- Chỉ ảnh hưởng browser quá cũ

---

## Submission Rules & Key Notes

- Phải là **registered researcher** và đang đăng nhập khi submit.
- Nếu một bug kéo theo nhiều CVE, Wordfence có thể chỉ trả **một bounty** cho issue có mức thưởng cao hơn.
- Wordfence phải là bên **handle responsible disclosure** nếu muốn report đủ điều kiện bounty.
- Researcher phải giữ bí mật issue cho đến khi Wordfence public disclosure.
- Nếu submit cùng một lỗ hổng tới tổ chức khác, report có thể **không còn đủ điều kiện bounty**.
- **First valid submission with working PoC** sẽ là submission được nhận bounty.
- Gửi quá nhiều report out of scope, false positive, low quality, hoặc AI hallucinated có thể dẫn tới:
  - throttling,
  - tạm chặn submit,
  - hoặc ban khỏi chương trình.
- Developer không thể nhận bounty cho lỗ hổng trong chính sản phẩm của họ, nhưng vẫn có thể submit để xin CVE/disclosure.

---

# Quick Comparison

## Patchstack - phù hợp khi
- Bạn muốn report cho **WordPress core, plugin, theme**
- Bạn cần một chương trình nhấn mạnh **valid unique reports + CVE + public disclosure**
- Bạn cần scope tương đối rõ theo **CVSS / privilege / active installs / public availability**

## Wordfence - phù hợp khi
- Bạn tập trung vào **plugins/themes** hơn là WordPress core
- Bạn muốn tận dụng scope rộng cho các loại **high threat** và **common dangerous** issues
- Bạn chấp nhận việc scope phụ thuộc nhiều vào **researcher tier**

## Điểm khác nhau quan trọng
- **Patchstack**: WordPress core là in scope.
- **Wordfence**: WordPress core là **out of scope asset** cho bounty.
- **Wordfence** có danh sách out-of-scope asset cụ thể theo vendor rất rõ.
- **Patchstack** nhấn mạnh mạnh vào tiêu chí public distribution, active installs, quyền khai thác, và uniqueness.

---

# Kết luận ngắn

Nếu mục tiêu là xác định nhanh một report có đáng submit hay không, có thể dùng checklist sau:

1. Component có **publicly distributed** không?
2. Có nằm trong **asset out of scope** không?
3. Có cần **Admin / high privilege** để exploit không?
4. Có **security impact rõ ràng** không?
5. Có tồn tại trên **latest version** không?
6. Có đủ **active installs** theo rule/tier không?
7. Có phải issue trùng, known, hoặc đã public chưa?
8. Có thể viết **PoC rõ ràng, reproducible** không?

Nếu 1 trong các điểm trên không đạt, khả năng cao report sẽ bị reject hoặc chỉ được xem xét ở mức CVE/disclosure thay vì bounty.
