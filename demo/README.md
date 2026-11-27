# Demo world for screenshots

A throwaway TDPdf Signing server filled with invented people, for the screenshots in the Signing guides at
docs.tdpdf.com. Nothing here touches production: the stack binds to `127.0.0.1`, its database lives in memory,
its mail goes to a local catcher, and `seed.mjs` refuses to run against anything that is not on localhost.

```sh
demo/up.sh          # start the stack: the same image production runs (taken from deploy/docker-compose.image.yml)
node demo/seed.mjs  # create the people and documents below
demo/up.sh down     # remove everything, including the database
```

The app is on <http://127.0.0.1:3190> and the mail catcher on <http://127.0.0.1:8125>. Avoid ports 3100 and 4000
on the machines that run this: other services own them. Re-running the seed needs a fresh stack
(`down`, then `up`).

## The cast

Everything is invented. Addresses are on `example.org`.

| Person | Role in the demo | Account |
|---|---|---|
| Maya Okafor, owner of Harbor Light Studio | Sends documents | yes (`maya@example.org`) |
| Tomas Reyes, admin at the studio | Second sender | yes (`tomas@example.org`) |
| Priya Nandakumar, Brightwell Dental | Signs the Studio Services Agreement | yes (`priya@example.org`) |
| Jonas Albrecht, Albrecht Bakery | Asked to sign the Photography Release | recipient only |
| Lena Moreau, Moreau Florals | Named on the Statement of Work Q1 | recipient only |

All accounts use the one demo password in `seed.mjs`. It is for this throwaway stack only.

## The documents

Maya owns all three, one in each state:

| Document | State | What happened |
|---|---|---|
| Studio Services Agreement | Completed | Sent to Priya, who signed it |
| Photography Release | Pending | Sent to Jonas, who has not signed |
| Statement of Work Q1 | Draft | Prepared for Lena, not sent |

## Rules for anything captured from it

- Use only the names and `example.org` addresses above.
- Phone numbers, if a screen needs one, are 555-0142 to 555-0149.
- Never capture the production server, and never reuse the demo's secrets elsewhere.
- The Signing guides' `shots` use personas `maya`, `tomas` and `priya`; the capture signs in as that account.
