-- migrate:up
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    -- stored trimmed and in lower case: one account per address
    email TEXT NOT NULL UNIQUE,
    -- a hash from spider.password.hash, never the password
    password_hash TEXT NOT NULL,
    -- what .roles on a route checks; make someone an admin with:
    --   UPDATE users SET role = 'admin' WHERE email = '...';
    role TEXT NOT NULL DEFAULT 'user',
    inserted_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TRIGGER IF NOT EXISTS users_set_updated_at
AFTER UPDATE ON users
FOR EACH ROW
BEGIN
    UPDATE users SET updated_at = datetime('now') WHERE id = NEW.id;
END;

-- migrate:down
DROP TRIGGER IF EXISTS users_set_updated_at;
DROP TABLE IF EXISTS users;
