# Demos

Small, complete apps built with the Spider of this repository, one folder
each. They are versioned and CI builds and tests every one of them on each
push (`zig build test` inside the folder), so a change to Spider that breaks
a demo fails the build.

| Demo | What it shows |
|---|---|
| [`books/`](books/) | A reading list: a page per book with a typed path parameter and a real 404 page, a reusable card component, a shared layout, a JSON API and Tailwind. |

Each demo depends on Spider through `.path = "../.."` in its
`build.zig.zon`: it always runs against the code next to it. An app of your
own depends on a released version instead (`spider new` writes that).

A demo is added here only once it has been reviewed and approved.
