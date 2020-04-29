git add .

msg="backup site source code $(date)"

if [ -n "$*" ]; then
	msg="$*"
fi
git commit -m "$msg"

git push origin master
