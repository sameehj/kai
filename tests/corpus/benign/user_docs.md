# Deploying the service

You need an API token to deploy. Ask your team lead to send the token to you
over the password manager, never over chat. Store it in `.env` and keep that
file out of git.

To rotate a leaked token, revoke it in the dashboard and send a new token
request to the platform team.

Agents can run the deploy script, but they should never read the token
themselves.
