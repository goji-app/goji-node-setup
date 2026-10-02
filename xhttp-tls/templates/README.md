# Decoy site templates

`install.sh` deploys one of these to `/var/www/decoy` (random by default,
`--template <name>` to choose; re-runs keep the one already deployed).
After editing anything here run `python build.py` to re-embed them into `install.sh`.

| Name | Source | License |
|---|---|---|
| analytics | written for this repo | — |
| blog | [westtle/simple-blog-template](https://github.com/westtle/simple-blog-template) | MIT (LICENSE) |
| docs | [JMcrafter26/tiny-docs](https://github.com/JMcrafter26/tiny-docs) (`tinydocs.html`) | MIT (LICENSE) |
| saas | [hannah-wright/saas-landing-page-template](https://github.com/hannah-wright/saas-landing-page-template) (`html/index.html`) | MIT (LICENSE) |

Each third-party template keeps its original LICENSE; it is served as `LICENSE.txt`.
