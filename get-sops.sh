# Download the latest release
LATEST=$(curl -s https://api.github.com/repos/getsops/sops/releases/latest | grep '"tag_name"' | cut -d '"' -f4)

wget https://github.com/getsops/sops/releases/download/${LATEST}/sops-${LATEST}.linux.amd64

# Make it executable
chmod +x sops-${LATEST}.linux.amd64

# Move it into your PATH
sudo mv sops-${LATEST}.linux.amd64 /usr/local/bin/sops

# Verify
sops --version