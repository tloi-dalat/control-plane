-- Run as root on the production VPS:  sudo mariadb < mysql-k8s-user.sql
-- (edit the password first, then don't leave it in this file).
--
-- A dedicated user for pods: only reachable from the k3s pod network (10.42.x.x)
-- and with its own password, never the development one.
-- Put the same password into Infisical as MYSQL__PASSWORD (production → /online-judge/core).
CREATE USER IF NOT EXISTS 'dmoj_k8s'@'10.42.%' IDENTIFIED BY 'CHANGEME-strong-password';
GRANT ALL PRIVILEGES ON dmoj.* TO 'dmoj_k8s'@'10.42.%';
-- The rehearsal copy (bootstrap/production/README.md). Drop both after cutover:
--   DROP DATABASE dmoj_rehearsal; REVOKE ALL ON dmoj_rehearsal.* FROM 'dmoj_k8s'@'10.42.%';
GRANT ALL PRIVILEGES ON dmoj_rehearsal.* TO 'dmoj_k8s'@'10.42.%';
FLUSH PRIVILEGES;
