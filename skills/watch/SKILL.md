# Watch

This skill sets up non-blocking monitoring for logs and long-running tasks.

## Rule: do not block session with infinite loops

Prefer background jobs via `nohup`, `tmux`, or `screen`.

## 1. Log watch

Example:
- `exec: "nohup sh -lc 'tail -F /var/log/syslog | grep -Ei \"error|panic|oom\" >> ~/.kai/watch-syslog.log' >/dev/null 2>&1 & echo $!"`

Track PID and output file path in the report.

## 2. Build watch

Wrap build command and monitor completion:
- `exec: "nohup sh -lc 'make -j$(nproc) > build.out 2>&1; echo $? > build.exit' >/dev/null 2>&1 & echo $!"`

Then periodically check:
- `exec: "test -f build.exit && cat build.exit || echo running"`

## 3. Process health watch

- `exec: "ps -p <pid> -o pid,pcpu,pmem,etime,cmd"`
- Alert if process exits or exceeds thresholds.

## 4. Multi-file watch

Use one watcher per source to avoid noisy combined pipelines.

## 5. Reporting

Use `report` for significant events only:
- service crash
- repeated OOM
- build finished (success/fail)
- sustained error pattern

Avoid alert spam; include timestamps and top 5 evidence lines.
