Table of Contents
Introduction
Reporting Protocol
Scope
Uniqueness Requirement
Quality Assurance
Rejection Criteria
Vendor Engagement
CVE Assignment
Research Points (XP)
CVSS Base Score (v3.1)
Active Install Count
Privilege Requirement Coefficients
Vulnerability Type Coefficients
Disclosure
Escalation Protocol
Attribution
Monthly Competition
Custom Events, Challenges
Monthly Bounty Pool
XP Requirement
Level Rewards
Zeroday Bounties
Benefits of Participation
Membership
Payouts
Communication
⚠️ Attention! New update, starting February 1, 2026 (00:00 UTC).

Introduction
1.1. Patchstack operates a public Bug Bounty Program focused on open-source software, primarily vulnerabilities within the WordPress ecosystem. More information is available at: https://patchstack.com/bug-bounty/

1.2. The program includes monthly competitions and occasional custom events throughout the year. Participation is open to anyone who submits valid and unique vulnerabilities in accordance with these rules.

1.3. All program operations, timelines, and communications follow Coordinated Universal Time (UTC).

1.4. Patchstack reserves the right to change or update these rules at any time, without prior notice.

1.5. All valid, in-scope vulnerabilities submitted through the Patchstack Bug Bounty Program will be publicly disclosed in the Patchstack Vulnerability Database.

1.6. Patchstack is a CVE Numbering Authority (CNA). This means that each valid, in-scope vulnerability will receive a unique CVE ID and be published in the CVE database, provided no conflicts exist with previously issued CVEs.

1.7. CVE assignment follows official CVE Program rules, with the following exception - assignment may be delayed to prevent CVE conflicts between multiple CNAs operating in the same ecosystem (for example, WordPress).

1.8. By participating in the Patchstack Bug Bounty Program, researchers can earn bounties by reporting valid, unique, and impactful security issues affecting in-scope components such as WordPress core, plugins, and themes.

1.9. By submitting a vulnerability to the Patchstack Bug Bounty Program, you agree to comply with all rules outlined in this document and any related documents.

Reporting Protocol
2.1. All vulnerability reports must be submitted ONLY through the official reporting form - https://patchstack.com/database/report

2.2. Reports sent via email or any other channel will not be accepted.

2.3. A researcher account is created automatically after at least one valid, in-scope vulnerability is submitted. You can access your account any time via this link - https://vdp.patchstack.com/researchers/login by using the email address you're using for vulnerability reporting.

2.4. Each researcher may operate only one account. Creating or using multiple accounts may result in immediate suspension of all related accounts.

2.5. Participation is open to individuals and companies that follow and respect the program rules.

2.6. Reports must be submitted by individual researchers or organizations. Team submissions are not supported, as the monthly competition system does not allow team-based point calculations.

Scope
3.1. The Patchstack Bug Bounty Program accepts vulnerability reports for components in the WordPress ecosystem, including:

WordPress core
WordPress plugins
WordPress themes
3.2. A vulnerability is considered valid only if it has a clear and measurable security impact.

3.3. Both free and premium plugins and themes are accepted. For premium components, researchers must provide the original, unmodified archive file for validation. If a theme depends on specific plugins, those plugins must also be provided.

3.4. The following are not accepted:

⚠️ Vulnerabilities with a CVSS v3.1 base score lower than 5.3 are not accepted for direct submission. Such vulnerabilities may only be accepted if they are first reported directly to the vendor, the vendor confirms the issue, and the vendor requests Patchstack to assign a CVE ID. In these cases, Patchstack may process the submission (there is an exception to the minimum CVSS score requirement of 5.3 - if the reported component has 100,000 or more active installs or reported component has active Patchstack mVDP program, reports with a CVSS score of 4.3 or higher are accepted.
⚠️ Vulnerabilities that require administrator or higher-level privileges (including similar custom roles).
⚠️ CAPTCHA or any other version of Turing test bypass.
⚠️ Arbitrary user registration by unprivileged/unauthenticated users, unless the vulnerability results in the creation of an arbitrary administrator account.
CSV injection vulnerabilities, as they depend on external actions outside WordPress and cannot be reliably evaluated.
IP spoofing issues, unless they directly affect a feature that relies on IP integrity (such as IP-based blocking) and is explicitly intended to resist spoofing.
Race condition vulnerabilities with a CVSS v3.1 base score below 7.0, unless a clear security impact is demonstrated.
Authenticated (Contributor or higher) shortcode preview issues, unless sensitive or security-related information (such as PII) is disclosed with measurable impact (this limitation does not apply to XSS vulnerabilities).
CSRF or Broken Access Control issues that only dismiss notices, unless the dismissal creates a real security impact.
IP bypass issues affecting non-critical actions (such as likes, views, or counters).
⚠️ Components with fewer than 100 active installs are generally considered out of scope, except in the following cases: a) the reported component is enrolled in an active Patchstack mVDP program, or b) the reported vulnerability has a CVSS v3.1 base score of 8.0 or higher and the component has 50 or more active installs, and prerequisite is not admin, or higher. In either case, such reports will be treated the same as reports for components with 100 active installs.
If the last version of the component was released more than three years ago.
If vulnerability doesn't exist in the latest version (for example patched by vendor, but never disclosed).
The component must be publicly available through WordPress.org, the vendor’s official website, or another publicly accessible source such as GitHub, CodeCanyon, or ThemeForest. Custom-made, modified, or private components that are not publicly distributed are not accepted.
Uniqueness Requirement
4.1. All reported vulnerabilities must be new and unique and must not have been previously reported or publicly disclosed.

4.2. Exceptions apply if the vulnerability was first reported directly to the vendor prior to submission to Patchstack. Such reports are accepted only if the vendor confirms the vulnerability and indicates a willingness to patch it. This requirement is mandatory for components developed or owned by Automattic, which must first be reported through Automattic’s HackerOne program.

4.3. If researcher account is suspended, all associated XP, vulnerability reports, and CVE assignments remain permanently linked to that account. They cannot be transferred or reassigned.

4.4. If multiple researchers report the same vulnerability (even across different parameters or endpoints), credit is given to the first valid submission. Attempts to manipulate the system, such as using multiple accounts or submitting duplicates across different bounty programs may result in penalties, including account suspension.

4.5. Incomplete patches that are publicly disclosed are not considered new vulnerabilities. However, if an incomplete patch introduces a new attack vector that was not possible before, it may be considered a new vulnerability.

Quality Assurance
5.1. All reports must be submitted using the official reporting form and must follow the form’s requirements: https://patchstack.com/database/report

5.2. Reports must be complete, accurate, and reproducible. Incomplete reports will be rejected. Researchers are given up to two chances to fix and resubmit rejected reports.

5.3. If a researcher has three rejected submissions within one month, they will be temporarily suspended from submitting reports for the rest of that month and the following month.

5.4. Each report must include:

A clear, step-by-step text-based proof of concept (PoC)
Steps starting from plugin or theme installation and ending with successful exploitation
All required raw HTTP request(s) in text form
The exact payload(s) used during testing
Video screenshots are highly appreciated
⚠️ 5.5. Repeated submission of false-positive vulnerability reports generated by AI tools will result in a one-month cooldown period, during which reports from the researcher will not be accepted and access to the account/dashboard will be temporarily suspended. If this behavior continues, the account will be permanently locked.

Rejection Criteria
6.1. Reports may be rejected for reasons including, but not limited to:

Incomplete or inaccurate information
Invalid vulnerability claims
Use of non-standard or modified user roles
Reports for closed or inaccessible plugins or themes are not accepted.
Patchstack may reject reports if the affected component is not publicly distributed through WordPress.org, Envato, GitHub, or another widely recognized repository.
Reports submitted by the vendor or developer of the affected component are accepted for disclosure purposes but are not eligible for bounties.
Vendor Engagement
7.1. Patchstack will use the most efficient publicly listed vendor contact channels for vulnerability reporting.

7.2. Contact methods that require account registration will be ignored.

7.3. If no contact details are available, the vulnerability may be disclosed immediately.

7.4. Vendors are notified once. It is the vendor’s responsibility to patch the issue promptly.

CVE Assignment
8.1. CVE IDs are assigned only after confirming there are no conflicts with existing CVEs. Assignment may be delayed to prevent duplicate CVE IDs across multiple CNAs.

8.2. If multiple researchers report the same vulnerability, the CVE is assigned to the first valid report. All later submissions are rejected.

8.3. Researchers may disclose vulnerabilities already reported to other programs by selecting the appropriate option during submission. In such cases, the vulnerability may be listed without a CVE ID.

Research Points (XP)
9.1. XP (Research Points) are awarded for valid vulnerability reports and are used to determine competition rankings and winners on monthly competitions and custom events.

9.2. XP calculations are based on several factors, described below.

9.3. XP calculated by adding multipliers (listed below) to the initial CVSS base score number.

CVSS Base Score (v3.1)
10.1. The CVSS v3.1 is the primary indicator of severity and must be calculated using the official calculator: https://www.first.org/cvss/calculator/3.1

10.2. We are using only CVSS base score for all the calculations.

Active Install Count
11.1. Each range applies a multiplier to the final XP score

11.2. For premium products, active installs are estimated based on sales volume.

Multiplier	Installs
x0.5	⚠️ 100+ active installs (only unauthenticated, subscriber, customer roles and CVSS 8.5+)
x0.75	⚠️ 500+ active installs (only unauthenticated, subscriber, customer roles and CVSS 8.0+)
x1	⚠️ 1K+ active installs (only unauthenticated, subscriber, customer roles and CVSS 7.0+)
x2	25K+ active installs
x3	50K+ active installs
x4	100K+ active installs
x5	200K+ active installs
x6	400K+ active installs
x7	800K+ active installs
x8	1.6 million+ active installs
x9	3.2 million+ active installs
x10	5 million+ active installs
x20	WordPress core
Privilege Requirement Coefficients
12.1. XP multipliers are applied based on the minimum privilege level required to exploit the vulnerability.

Multiplier	Level of privilege
-	⚠️ Admin, SuperAdmin (not accepted)
x0.25	Shop Manager (WooCommerce)
x0.5	Author and Editor
x0.75	Contributor
x1	Subscriber and Customer (WooCommerce)
x2	Unauthenticated
Vulnerability Type Coefficients
13.1. XP multipliers are applied based on vulnerability type.

Multiplier	Vulnerability type
x3	Remote Code Execution (RCE), Arbitrary file upload, deletion, Privilege escalation to Admin users, Arbitrary code execution
x2	SQL Injection (SQLi), PHP Object Injection, Insecure Deserialization, Local File Inclusion (LFI)
x1.5	Arbitrary file download/deletion, Privilege escalation to Non-Admin users
x0.25	Cross-Site Request Forgery (CSRF)
x0.2	Race Condition
13.2. If a CSRF vulnerability leads to another vulnerability type (for example, CSRF leading to RCE), both multipliers apply.

13.3. If install or sales numbers cannot be reliably determined, Patchstack may use public data sources such as Google SERPs or PublicWWW.

13.4. XP is calculated monthly or within the timeframe of a specific custom event. Ongoing results appear on the leaderboard: https://patchstack.com/database/leaderboard

13.5. Final results are announced after all reports are validated (up to 10 business days if a backlog of reports requires more time for processing).

Disclosure
14.1. All vulnerabilities are publicly disclosed to the Patchstack Vulnerability Database according to the Patchstack Vulnerability Disclosure Policy.

14.2. Disclosure may be delayed until a fix is released and sufficient user adoption is observed.

14.3. Policy details: https://patchstack.com/patchstack-vulnerability-disclosure-policy/

14.4. Researchers must not disclose vulnerability details to any third parties before official public disclosure by Patchstack, which occurs when the vulnerability is publicly visible in the Patchstack Vulnerability Database and the assigned CVE is published.

14.5. To comply with EU CRA requirements all publications will be instant once the patch is released and validated (or released after validation).

14.6. The patch must be released as a dedicated update containing only security-related changes, with no additional code modifications. The version number or changelog description must clearly indicate that the release is a security fix.

Escalation Protocol
15.1. If a vendor does not respond within 14 days, Patchstack may proceed with public disclosure and may notify relevant security teams.

15.2. For components enrolled in Patchstack mVDP, disclosure timelines may be extended. Disclosure may be accelerated in cases of active exploitation or third-party disclosure.

15.3. If a vendor overlooks a report and the vulnerability is publicly disclosed, they may contact us at triage@patchstack.com to receive prompt assistance with vulnerability details, quick patch validation, and issue resolution.

Attribution
16.1. Public disclosures include researcher attribution using the provided name or nickname, and include ‘Patchstack Bug Bounty Program’ for program recognition.

16.2. CVE IDs are published in the global CVE database after disclosure with the same researcher data as in the Patchstack Vulnerability Database entry.

Monthly Competition
17.1. Monthly competitions run from the first day of the month at 00:00 UTC to the last day at 23:59 UTC.

17.2. Results are announced on the Patchstack Alliance Discord server.

17.3. Patchstack guarantees a minimum monthly bounty pool of $8,800, distributed based on final rankings.

17.4. Leaderboard: https://patchstack.com/database/leaderboard

Custom Events, Challenges
18.1. Custom events and CTF games are announced on Discord as well as their rules.

18.2. Custom challenges might be announced for extra bounties as a part of monthly competition.

Monthly Bounty Pool
19.1. Monthly bounties are distributed based on final leaderboard rankings as follows:

Rank	Bounty
1st place	$2,000
2nd place	$1,400
3rd place	$800
4th place	$600
5th place	$500
6th–10th place	$400
11th–15th place	$200
16th–19th place	$100
20th place + one random researcher	$50
19.2. A random bounty of $50 is awarded to one randomly selected researcher outside the top 20 rankings who has submitted at least one valid report with XP greater than 0.

19.3. High-impact vulnerabilities may be eligible for individual bounty rewards even if they do not qualify for the Zeroday program. Such cases are evaluated individually and must be discussed by opening a support ticket on the Patchstack Alliance Discord server in the #support channel.

XP Requirement
20.1. Bounties are paid only if the researcher has more than 0 XP for the respective month. If a researcher has 0 XP, no bounty will be paid, even if their leaderboard position qualifies for a reward. This rule also applies to random rewards.

Level Rewards
21.1. Researchers receive passive rewards for accumulating XP and progressing through levels. XP is earned through:

Monthly competitions
Custom events
Patchstack Zeroday bounties
21.2. Levels reset to Level 1 at the beginning of each year. Updated level-related rules are announced after final monthly and yearly results are confirmed.

21.3. Starting from Level 1, researchers unlock additional rewards. These rewards are paid together with monthly bounties.

Level	XP Required	Reward
Level 1	100	$50
Level 2	300	$100
Level 3	600	$200
Level 4	1,000	$300
Level 5	1,700	$500
Level 6	2,700	$700
Level 7	4,000	$1,000
Level 8	5,500	$1,337
Level 9	7,500	$1,700
Level 10	10,000	$2,500
Level 11	13,000	$3,500
Level 12	19,000	$5,000
Zeroday Bounties
22.1. Patchstack offers Zeroday bounties for high-impact vulnerabilities on a case-by-case basis (bounty per vulnerability).

22.2. Zeroday rewards are paid together with monthly bounties.

22.3. Zeroday Bounties are:

Active Installs	Unauthenticated	Subscriber / Customer
1,000+	$250	$125
5,000+	$400	$200
10,000+	$600	$300
50,000+	$1,400	$700
100,000+	$2,600	$1,300
500,000+	$4,900	$2,450
1,000,000+	$7,200	$3,600
5,000,000+	$14,400	$7,200
15,000,000+ or WordPress Core (latest stable)	$33,000	$16,500
22.4. Zeroday bounty requirements are

To qualify for a Zeroday bounty, all of the following conditions must be met:
The component is a free or premium WordPress plugin, theme, or WordPress core
(excluding components hosted in private, non-public repositories)
The vulnerability leads to a full site compromise, including the ability to upload and access a functional backdoor
Exploitable by:
Unauthenticated users, or
Subscriber / Customer (WooCommerce) roles or lower
The report includes a working exploit
No prerequisites are required:
Latest stable version
Default settings
Common environment
No additional vulnerabilities required
Exploitation does not require user interaction
The vulnerability:
Has not been reported elsewhere
Is not previously known to the vendor
Is not publicly disclosed
The vulnerability is eligible under all other Patchstack program rules
End-of-life components or components not updated in the last three years are not accepted
Any required POP chain must exist in:
The latest WordPress core version at the time of submission, or
The affected component itself
A single vulnerability affecting multiple components is treated as one issue, resulting in:
One bounty payout
One CVE ID
Total active installs across all affected components used to calculate impact
22.5. Valid Zeroday vulnerabilities are not included into XP for the monthly competition or levels as they are rewarded separately.

22.6. XP points earned from Zero-day reports do not contribute to level progression (21. Level Rewards), as these reports are rewarded on a per-bounty, per-report basis.