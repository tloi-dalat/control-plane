-- Run as root on the dev VPS:  sudo mysql < mysql-k8s-user.sql
-- (edit the password first, then don't leave it in this file).
--
-- A dedicated user for pods: only reachable from the k3s pod network (10.42.x.x)
-- and with a fresh password — the old dev one appeared in a chat transcript.
-- Use the same password when bootstrap/seal-secrets.sh asks for MYSQL__PASSWORD.
CREATE USER IF NOT EXISTS 'dmoj_k8s'@'10.42.%' IDENTIFIED BY 'CHANGEME-strong-password';
GRANT ALL PRIVILEGES ON dmoj.* TO 'dmoj_k8s'@'10.42.%';
FLUSH PRIVILEGES;
