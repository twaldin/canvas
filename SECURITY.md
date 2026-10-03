# Security

Please report vulnerabilities privately: [open a draft security advisory](https://github.com/twaldin/easl/security/advisories/new) (GitHub's private vulnerability reporting). Don't open a public issue for them.

What matters most: Easl runs a local API that can type into terminals, run agents, and drive browser tiles. Its Unix sockets (`easl.sock`, `cmux.sock` in `~/Library/Application Support/Easl/`, mode `0600`) accept any process of the logged-in user, by design (docs/contracts.md, "Sockets"). A way for anything else to reach them, for a web page in a browser or HTML tile to call the API or run code outside its sandbox, or for a board, note, or file opened in Easl to run commands without the user asking, is a vulnerability.

Only the latest release gets fixes.
