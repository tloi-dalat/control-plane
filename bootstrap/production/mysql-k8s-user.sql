-- Run as root on the production VPS:  sudo mysql < mysql-k8s-user.sql
-- (edit the password first, then don't leave it in this file).
--
-- A dedicated user for pods: only reachable from the k3s pod network (10.42.x.x)
-- and with its own password, never the development one.
-- Put the same password into Infisical as MYSQL__PASSWORD (production → /online-judge/core).
CREATE USER IF NOT EXISTS 'dmoj_k8s'@'10.42.%' IDENTIFIED BY 'CHANGEME-strong-password';
GRANT ALL PRIVILEGES ON dmoj.* TO 'dmoj_k8s'@'10.42.%';
FLUSH PRIVILEGES;
