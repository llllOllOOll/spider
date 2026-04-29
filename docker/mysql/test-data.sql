-- Test data for Spider MySQL testing
CREATE DATABASE IF NOT EXISTS spider_db;
USE spider_db;

-- Create test tables
CREATE TABLE IF NOT EXISTS todos (
    id INT AUTO_INCREMENT PRIMARY KEY,
    title VARCHAR(255) NOT NULL,
    completed BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS products (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    price DECIMAL(10,2) NOT NULL,
    category VARCHAR(100),
    in_stock BOOLEAN DEFAULT TRUE
);

-- Clear and insert fresh test data
TRUNCATE TABLE todos;
INSERT INTO todos (title, completed) VALUES
    ('Test MySQL driver', FALSE),
    ('Implement query execution', FALSE),
    ('Add transaction support', FALSE),
    ('Test connection pooling', FALSE),
    ('Write comprehensive tests', FALSE);

TRUNCATE TABLE products;
INSERT INTO products (name, price, category, in_stock) VALUES
    ('Zig Programming Book', 29.99, 'Books', TRUE),
    ('MySQL Server License', 0.00, 'Software', TRUE),
    ('Web Framework Template', 49.99, 'Templates', FALSE),
    ('Database Connector', 15.50, 'Libraries', TRUE);

-- Create user for Spider application
CREATE USER IF NOT EXISTS 'spider'@'%' IDENTIFIED BY 'spider_password';
GRANT ALL PRIVILEGES ON spider_db.* TO 'spider'@'%';
FLUSH PRIVILEGES;

-- Show data for verification
SELECT 'Todos:' as '';
SELECT * FROM todos;

SELECT 'Products:' as '';
SELECT * FROM products;