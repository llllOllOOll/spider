-- migrate:up
CREATE TABLE IF NOT EXISTS users (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    -- stored trimmed and in lower case: one account per address
    email VARCHAR(255) NOT NULL UNIQUE,
    -- a hash from spider.password.hash, never the password
    password_hash TEXT NOT NULL,
    -- what .roles on a route checks; make someone an admin with:
    --   UPDATE users SET role = 'admin' WHERE email = '...';
    role VARCHAR(50) NOT NULL DEFAULT 'user',
    inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS users_set_updated_at ON users;
CREATE TRIGGER users_set_updated_at
BEFORE UPDATE ON users
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

-- migrate:down
DROP TRIGGER IF EXISTS users_set_updated_at ON users;
DROP TABLE IF EXISTS users;
