-- Initialize Spider MySQL database
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

CREATE TABLE IF NOT EXISTS users (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Insert test data
INSERT IGNORE INTO todos (title, completed) VALUES
    ('Learn Zig', FALSE),
    ('Build Spider MySQL driver', FALSE),
    ('Test MySQL integration', FALSE);

INSERT IGNORE INTO users (name, email) VALUES
    ('Spider User', 'spider@example.com'),
    ('Test User', 'test@example.com');

-- Create user for Spider application
CREATE USER IF NOT EXISTS 'spider'@'%' IDENTIFIED BY 'spider_password';
GRANT ALL PRIVILEGES ON spider_db.* TO 'spider'@'%';
FLUSH PRIVILEGES;

-- Show tables for verification
SHOW TABLES;