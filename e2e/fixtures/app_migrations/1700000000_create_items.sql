-- migrate:up
CREATE TABLE fixture_items (id int);

-- migrate:down
DROP TABLE fixture_items;
