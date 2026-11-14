# books

A small reading list that shows, in one complete app, how a Spider app is
put together: a shelf of books as cards, a page per book, an about page, a
404 page, and a JSON API, styled with Tailwind. No database: the books are
a fixed list in `src/features/books/model.zig`.

| URL | What answers |
|---|---|
| `/` | The shelf: `books/index.html` loops over the books and renders a `<BookCard />` for each |
| `/books/:id` | One book. `spider.Path(u32, "id")`: `/books/banana` is a 404 before the handler runs; `/books/99` is a 404 from the handler (`error.NotFound`) |
| `/about` | A static page |
| `/api/health` | `ok`, as plain text |
| `/api/books` | The shelf as JSON (`c.json`) |
| anything else | The 404 page, `src/shared/templates/not_found.html` (`spider.errorHandler(.{ .not_found_view = "not_found" })`) |

## Run it

From this folder, with Zig 0.17.0 and the `spider` CLI:

```sh
spider install     # Tailwind, daisyUI, htmx, Alpine and icons into bin/ and public/ (SHA-256 checked)
spider dev         # builds, runs on http://localhost:3000 and reloads the browser on save
```

or `zig build run` for a single build and run.

## Test it

```sh
zig build test
```

runs the app's tests: requests against the running server
(`src/app_test.zig`: every page, the 404s, the JSON), the access contract
of the routes (`src/features/books/routes_test.zig`), and Spider's
conventions (`spider check`). It needs no download.

## Where things are

- `src/main.zig`: the server, the error handler and its 404 page.
- `src/features/books/`: `model.zig` (the data), `controller.zig` (the
  handlers), `routes.zig` (the routes), `views/` (the pages).
- `src/shared/templates/`: `layout.html` (the page shell and the nav every
  page extends), `book_card.html` (the `<BookCard />` component, whose
  first line declares its props: `-- props: id!, title!, author!, year:
  int, finished: bool = false`),
  `not_found.html`.
