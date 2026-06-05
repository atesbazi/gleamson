# Publishing `gleamson` to Hex / HexDocs

`gleam publish` uploads the package to [Hex](https://hex.pm) and, in the same
step, builds the HTML docs and uploads them to
[HexDocs](https://hexdocs.pm). One command does both.

## 0. Prerequisites

- Gleam and Erlang/OTP installed (`gleam --version`).
- A **Hex account**. Create one at <https://hex.pm/signup> and **verify your
  email** — publishing is blocked until the email is confirmed.

## 1. Check the package name is free

The name must be unique on Hex. Open <https://hex.pm/packages/gleamson>. If it
404s, the name is available. If it's taken, rename the package (change `name`
in `gleam.toml` and the `src/gleamson.gleam` / `src/gleamson/` paths accordingly).

## 2. Fill in `gleam.toml` metadata

Hex shows this on the package page. Required: `name`, `version`. Strongly
recommended: `licences` (SPDX), `description`, `repository`, `links`.

```toml
name = "gleamson"
version = "0.1.0"
licences = ["Apache-2.0"]
description = "A fast, pure-Gleam JSON library with a transparent value tree and combinator decoders"
repository = { type = "github", user = "YOUR_GITHUB_USER", repo = "gleamson" }
links = [{ title = "Website", href = "https://github.com/YOUR_GITHUB_USER/gleamson" }]
```

Update `YOUR_GITHUB_USER` (or remove `repository`/`links` if you don't have a
repo yet).

## 3. Add a LICENCE file

Hex expects the licence text to ship with the package. The simplest way to get
the Apache-2.0 text:

- Run `gleam new tmp` in a scratch directory and copy the generated `LICENCE`
  file into your `gleamson` folder, **or**
- Download <https://www.apache.org/licenses/LICENSE-2.0.txt> and save it as
  `LICENCE`.

## 4. Build, test, and tidy warnings

```sh
cd gleamson
gleam build
gleam test
```

Fix any warnings (e.g. unused imports). A clean build is the goal before you
publish.

## 5. Preview the documentation locally

```sh
gleam docs build
```

Open `build/dev/docs/gleamson/index.html` in a browser and check that your module
doc comments (`////`) and function comments (`///`) render the way you want.
This is exactly what will land on HexDocs.

## 6. Publish

```sh
gleam publish
```

What happens the first time:

1. Gleam asks for your Hex **username/email and password**.
2. It exchanges them for a long-lived API token and asks you to set a **local
   password** to encrypt that token on disk. From then on it only asks for the
   local password, never your Hex password again.
3. It prints the **list of files** that will be included. Confirm that your
   sources are there — you should see `src/gleamson.gleam`,
   `src/gleamson/decode.gleam`, `gleam.toml`, `README.md`, and `LICENCE`.
4. It uploads the release and the generated docs.

When it finishes:

- Package: <https://hex.pm/packages/gleamson>
- Docs: <https://hexdocs.pm/gleamson/>

## 7. Releasing new versions

Bump `version` in `gleam.toml` (Hex versions are immutable — you cannot
overwrite an existing one), then run `gleam publish` again.

Useful follow-ups:

- `gleam publish --replace` — re-upload the **same** version, only allowed
  within a short window after the original publish.
- `gleam hex retire gleamson 0.1.0 security "reason"` — mark a bad release as
  retired so people are warned off it (it stays downloadable for those who
  pinned it).
- For CI, `gleam publish --yes` skips the confirmation, and the `HEXPM_USER` /
  `HEXPM_PASS` environment variables can supply credentials non-interactively.

## Using it after publishing

In any Gleam project:

```sh
gleam add gleamson
```

Then drop the `{ path = "../gleamson" }` line from local projects and use the
published version instead.
