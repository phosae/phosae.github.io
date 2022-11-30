git add .

msg="backup site source code $(date +%F-%A-%T)"

if [ -n "$*" ]; then
	msg="$*"
fi
git commit -m "$msg"

git push origin master
