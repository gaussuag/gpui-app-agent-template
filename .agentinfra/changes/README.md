# ChangeSpec lifecycle

Commit one `ready` ChangeSpec here for each full or governance change, in the
first commit whose parent is the runner-owned task start. The file must remain
tracked, present, uniquely resolvable in that task range, clean at final
validation, and keep its original change ID and declared task start. Directory
placement, staging, or an untracked file does not establish committed
provenance. The file records authorization and expected verification; it is not
evidence that any check passed. Focused and bot lanes generate an equivalent
temporary contract outside the repository and do not add routine JSON files
here.

Each committed ChangeSpec remains as review history. A later policy version may
add an explicit archival process; v0.2 Core does not move or rewrite records.
