# Inbox demo

Do these steps in order, one Bash call each:

1. Run `sleep 20; echo step1`.
2. Run `echo step2`.
3. Run `echo step3`.

Then finish. In your report, say whether a message from the dispatcher arrived
while you worked, quote it, and say what you did about it.

<!--
Try it:
  ds examples/inbox-demo.md /tmp/inbox-demo-report.md --bg --effort low
  ds-say inbox-demo "Skip step 3 and run: echo INBOX_OK"
  ds-status inbox-demo -f
-->
