# !/bin/bash
cd
rm -rf swu_blog_deploy
git clone https://github.com/dev-library/swu_blog_deploy.git
cd swu_blog_deploy
chmod +x ./gradlew
./gradlew clean build -x test