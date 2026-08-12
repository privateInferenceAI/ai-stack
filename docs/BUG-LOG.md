# BUG LOG — every scar became a rule

(Paste the master bug table 1–52 from the build log here, plus 53–58 from the runbooks.)

| # | § | Symptom → Fix |
|---|---|---|
| 59 | git | Tarball deployment hid version drift → Git repo is source of truth; boxes pull, never push except hotfix commits |
| 60 | git | Git doesn't track empty dirs or permissions → gittar.sh creates runtime dirs + ownership after every clone |
