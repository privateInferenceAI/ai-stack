# PATH A — Clone (restore from backup)

**Note on Git:** backup/restore is Git-independent — it captures live state
(config + data), not the repo. After a restore, the box's /opt/ai-stack is NOT
a git checkout. To re-link it to the repo (optional, for future git pulls):
