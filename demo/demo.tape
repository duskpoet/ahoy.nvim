# ahoy.nvim README demo. Offline: gh and curl are shims (demo/fake.lua), nothing touches GitHub.
#   demo/setup.sh && vhs demo/demo.tape
# Re-run setup.sh before each take: the take checks out a branch in the sandbox repo.

Output "demo/ahoy.mp4"
Output "demo/ahoy.gif"

Require nvim
Set Shell "bash"
Set FontSize 16
Set Width 1720
Set Height 880
Set Padding 20
Set Theme "nord"
Set TypingSpeed 90ms
Set Framerate 30

Hide
Type "source /tmp/ahoy-demo/env.sh && clear"
Enter
Sleep 300ms
Show

# 1. Same command as always: the dashboard fills in.
Sleep 600ms
Type "nvim"
Sleep 300ms
Enter
Sleep 3.5s

# 2. Review request → <CR>: gh pr checkout + fugitive difftool.
Type@250ms "}}jj"
Sleep 900ms
Enter
Sleep 3s

# 3. Same key, different dashboard: the PR layout.
Ctrl+W
Type "o"
Sleep 400ms
Type " a"
Sleep 4s
Screenshot "demo/ahoy-pr.png"

# 4. <CR> on the failing check: `gh run view --log-failed` in a split; q closes it.
Type@250ms "}}}kk"
Sleep 700ms
Enter
Sleep 2.8s
Type "q"
Sleep 800ms

# 5. <CR> on an unresolved thread: jump to file:line.
Type@250ms "}jj"
Sleep 700ms
Enter
Sleep 2.5s

# 6. Back to the dashboard; hold (loop point).
Type " a"
Sleep 4s
Sleep 500ms
