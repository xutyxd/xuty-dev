#!/usr/bin/env bash
#
# sops-secret.sh — Helper to encrypt secrets of Kubernetes with SOPS + Age
# Use: ./sops-secret.sh [options]
#
# Examples:
#   ./sops-secret.sh -n blog-db -N blog -l DB_PASSWORD=secret123 -l DB_USER=bloguser
#   ./sops-secret.sh -n tls-cert -N ingress-nginx -f ./cert.pem=tls.crt -f ./key.pem=tls.key
#   ./sops-secret.sh -n app-env -N default --env-file .env
#   ./sops-secret.sh -n blog-db -N blog -l DB_PASSWORD=NewPass --edit
#

set -euo pipefail

# ───--- Colors ---───────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ───--- Default values ---───────────────────────────────────────────────
SECRET_NAME=""
NAMESPACE="default"
OUTPUT_DIR="secrets"
LITERALS=()
FILES=()
ENV_FILE=""
EDIT_MODE=false
DRY_RUN=false
SECRET_TYPE="generic"

# ───--- Help ---─────────────────────────────────────────────────────────
usage() {
    cat <<EOF
${BOLD}sops-secret.sh${RESET} — Encrypt secrets of Kubernetes with SOPS + Age

${BOLD}Use:${RESET}
  ./sops-secret.sh [opciones]

${BOLD}Opciones:${RESET}
  -n, --name NAME           Name of secret (required)
  -N, --namespace NS        Namespace destination (default: default)
  -o, --output-dir DIR       Output directory (default: secrets)
  -l, --literal KEY=VALUE   Variable of environment literal (can repeat)
  -f, --file PATH=KEY       File as value of secret (can repeat)
  -e, --env-file PATH       .env file with variables
  -t, --type TYPE           Secret type: generic, tls, docker-registry (default: generic)
  -E, --edit                Edit an encrypted secret
  -d, --dry-run             Show YAML without saving or encrypting
  -h, --help                Show this help

${BOLD}Examples:${RESET}
  ${CYAN}# Create secret with literal vars${RESET}
  ./sops-secret.sh -n blog-db -N blog \\
      -l DB_PASSWORD=SuperSecret123 \\
      -l DB_USER=bloguser

  ${CYAN}# Create secret TLS from file${RESET}
  ./sops-secret.sh -n tls-cert -N ingress-nginx -t tls \\
      -f ./cert.pem=tls.crt \\
      -f ./key.pem=tls.key

  ${CYAN}# Create secret from file .env${RESET}
  ./sops-secret.sh -n app-config -N api --env-file ./.env

  ${CYAN}# Edit an existing secret${RESET}
  ./sops-secret.sh -n blog-db -N blog -l DB_PASSWORD=NewPass --edit

EOF
    exit 0
}

# ───--- Argument parse ---───────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--name)
            SECRET_NAME="$2"
            shift 2
            ;;
        -N|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -o|--output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -l|--literal)
            LITERALS+=("$2")
            shift 2
            ;;
        -f|--file)
            FILES+=("$2")
            shift 2
            ;;
        -e|--env-file)
            ENV_FILE="$2"
            shift 2
            ;;
        -t|--type)
            SECRET_TYPE="$2"
            shift 2
            ;;
        -E|--edit)
            EDIT_MODE=true
            shift
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo -e "${RED}✗ Unknown option: $1${RESET}"
            echo "  Use -h or --help to see help"
            exit 1
            ;;
    esac
done

# ───--- Validations ---──────────────────────────────────────────────────
if [[ -z "$SECRET_NAME" ]]; then
    echo -e "${RED}✗ Error: --name es required${RESET}"
    echo "  Use -h or --help to see help"
    exit 1
fi

if $EDIT_MODE; then
    EXISTING_FILE="$OUTPUT_DIR/$SECRET_NAME.yaml"
    if [[ ! -f "$EXISTING_FILE" ]]; then
        echo -e "${RED}✗ Error: Secret to edit doesn't exist: $EXISTING_FILE${RESET}"
        exit 1
    fi
    if [[ ${#LITERALS[@]} -eq 0 && ${#FILES[@]} -eq 0 && -z "$ENV_FILE" ]]; then
        echo -e "${RED}✗ Error: In --edit mode, you must provide at least one new variable${RESET}"
        exit 1
    fi
else
    if [[ ${#LITERALS[@]} -eq 0 && ${#FILES[@]} -eq 0 && -z "$ENV_FILE" ]]; then
        echo -e "${RED}✗ Error: You must provide at least one variable (-l), file (-f) or .env (-e)${RESET}"
        exit 1
    fi
fi

# ───--- Verify deps ---──────────────────────────────────────────────────
check_cmd() {
    if ! command -v "$1" &>/dev/null; then
        echo -e "${RED}✗ '$1' not installed${RESET}"
        echo "  Install it before continuing"
        exit 1
    fi
}

check_cmd kubectl
check_cmd sops
check_cmd age

# ───--- Verify .sops.yaml ---─────────────────────────────────────────
if [[ ! -f ".sops.yaml" ]]; then
    echo -e "${RED}✗ .sops.yaml not found in current directory${RESET}"
    echo "  Run ./setup-sops.sh to create it or"
    echo "  Create one with your public Age key:"
    echo ""
    echo "  creation_rules:"
    echo "    - path_regex: secrets/.*\\.yaml$"
    echo "      encrypted_regex: '^(data|stringData)$'"
    echo "      age: <YOUR_PUBLIC_AGE_KEY>"
    echo ""
    exit 1
fi

# ───--- Edit mode ---────────────────────────────────────────────────────
if $EDIT_MODE; then
    echo -e "${BLUE}🔓 Decrypting $EXISTING_FILE...${RESET}"
    sops --decrypt --in-place "$EXISTING_FILE"

    echo -e "${BLUE}✏️  Edit the file and then re-encrypt:${RESET}"
    echo -e "  ${CYAN}sops --encrypt --in-place $EXISTING_FILE${RESET}"
    echo ""
    echo -e "${YELLOW}💡 Or use:${RESET}"
    echo -e "  ${CYAN}EDITOR=vim sops edit $EXISTING_FILE${RESET}"
    exit 0
fi

# ───--- Build temporal Secret ---────────────────────────────────────────
TMP_DIR=$(mktemp -d)
TMP_SECRET="$TMP_DIR/secret.yaml"

echo -e "${BLUE}🔐 BUilding temporal Secret...${RESET}"

KUBECTL_ARGS=("create" "secret")

if [[ "$SECRET_TYPE" == "tls" ]]; then
    KUBECTL_ARGS+=("tls" "$SECRET_NAME" "--namespace=$NAMESPACE")
else
    KUBECTL_ARGS+=("generic" "$SECRET_NAME" "--namespace=$NAMESPACE")
fi

for lit in "${LITERALS[@]}"; do
    KUBECTL_ARGS+=("--from-literal=$lit")
done

for f in "${FILES[@]}"; do
    KUBECTL_ARGS+=("--from-file=$f")
done

if [[ -n "$ENV_FILE" ]]; then
    if [[ ! -f "$ENV_FILE" ]]; then
        echo -e "${RED}✗ File .env doesnt exists: $ENV_FILE${RESET}"
        rm -rf "$TMP_DIR"
        exit 1
    fi
    KUBECTL_ARGS+=("--from-env-file=$ENV_FILE")
fi

KUBECTL_ARGS+=("--dry-run=client" "-o" "yaml")

kubectl "${KUBECTL_ARGS[@]}" > "$TMP_SECRET"

# ───--- Dry run: show and exit ---───────────────────────────────────────
if $DRY_RUN; then
    echo -e "${CYAN}📄 Secret generated (plain text, ${RED}Do NOT upload this to Git.${CYAN}):${RESET}"
    cat "$TMP_SECRET"
    rm -rf "$TMP_DIR"
    exit 0
fi

# ───--- Encrypt with SOPS ---────────────────────────────────────────────
echo -e "${BLUE}🔒 Encrypting with SOPS + Age...${RESET}"

mkdir -p "$OUTPUT_DIR"
OUTPUT_FILE="$OUTPUT_DIR/$SECRET_NAME.yaml"

sops --encrypt --in-place "$TMP_SECRET"

# Mover al destino final
mv "$TMP_SECRET" "$OUTPUT_FILE"

# ───--- Clean ---────────────────────────────────────────────────────────
rm -rf "$TMP_DIR"
echo -e "${BLUE}🧹 Temporal files cleaned!${RESET}"

# ───--- Verify ---───────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}📄 Preview of encrypted secret:${RESET}"
head -n 12 "$OUTPUT_FILE"
echo "  ..."

# ───--- Resume ---───────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}📋 Resume:${RESET}"
echo -e "  ${CYAN}Name:${RESET}     $SECRET_NAME"
echo -e "  ${CYAN}Namespace:${RESET}  $NAMESPACE"
echo -e "  ${CYAN}Type:${RESET}       $SECRET_TYPE"
echo -e "  ${CYAN}File:${RESET}    $OUTPUT_FILE"
echo ""
echo -e "${YELLOW}💡 Next steps:${RESET}"
echo -e "  1. ${CYAN}git add $OUTPUT_FILE${RESET}"
echo -e "  2. ${CYAN}git commit -m \"secrets($SECRET_NAME): add/update secret\"${RESET}"
echo -e "  3. ${CYAN}git push origin main${RESET}"
echo -e "  4. Flux will synchronize automatically."
echo ""
echo -e "${GREEN}🚀 Ready!${RESET}"