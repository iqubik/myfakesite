# file: readme.txt v1.0
Еастройка под себя:
Замените:
docker-compose.yml
      - /etc/letsencrypt/live/YOUDOMEN.XXX/fullchain.pem:/etc/nginx/certs/fakesite.crt:ro
      - /etc/letsencrypt/live/YOUDOMEN.XXX/privkey.pem:/etc/nginx/certs/fakesite.key:ro
nginx.conf
server {
    listen 80;
    server_name YOUDOMEN.XXX;
и
server {
    listen 443 ssl;
	server_name YOUDOMEN.XXX;
и почту
return 200 'Contact: mailto:admin@YOUDOMEN.XXX