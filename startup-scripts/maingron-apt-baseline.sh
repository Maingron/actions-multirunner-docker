apt update
apt upgrade -y
apt install -y --no-install-recommends curl cargo rustup
rustup update stable
cargo install oxipng
