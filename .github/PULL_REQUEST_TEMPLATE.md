## Summary
<!-- What does this change and why? -->

## Type of change
- [ ] Bug fix
- [ ] New feature
- [ ] Refactor / cleanup
- [ ] Docs / comments only
- [ ] CI / workflow change

## Breaking changes
- [ ] This change requires host-side setup (volume layout, permissions, env vars)
- [ ] This change alters the container entrypoint or startup behaviour

<!-- If checked, describe what users need to do, e.g.:
     rename ./ssh/authorized_keys → place it inside a ./ssh/ directory -->

## Testing
<!-- How did you test this? -->

## Checklist
- [ ] `docker compose build` passes locally
- [ ] Container starts and sshd is running (`docker ps` shows healthy)
- [ ] No secrets or SSH keys committed to the image
- [ ] Host-side setup documented above if behaviour changed
- [ ] CI passes
- [ ] README / docs updated if user-facing behaviour changed
- [ ] Linked issue: Closes #____
