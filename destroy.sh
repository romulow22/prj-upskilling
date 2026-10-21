#!/bin/bash
#==============================================================
# destroy.sh - Remove a Infra Code Server (ordem inversa do deploy)
#
# Uso:
#   ./destroy.sh                 # pede confirmação
#   CONFIRMAR=sim ./destroy.sh   # sem confirmação interativa
#
# Mantidos intencionalmente:
#   - Bucket S3 e chave KMS dos logs do CloudTrail (evidência de auditoria)
#   - Key Pair e bucket de templates
#==============================================================
set -euo pipefail

REGION="${REGION:-us-east-1}"
BUCKET="${BUCKET:-contabil-11111992}"
KEY_NAME="${KEY_NAME:-code-server}"

STACK_REDE="infraContabil"
STACK_EC2="vscodeServer"
STACK_AUDITORIA="upsk-auditoria"
STACK_MONITORAMENTO="upsk-monitoramento"
STACK_DASHBOARD="upsk-dashboard"
STACK_BACKUP="upsk-backup"
STACK_CUSTOS="upsk-custos"

# A EC2 sai antes da rede (usa os exports de subnet e security group)
ORDEM=(
  "${STACK_CUSTOS}"
  "${STACK_DASHBOARD}"
  "${STACK_MONITORAMENTO}"
  "${STACK_BACKUP}"
  "${STACK_AUDITORIA}"
  "${STACK_EC2}"
  "${STACK_REDE}"
)

stack_existe() {
  aws cloudformation describe-stacks \
    --stack-name "$1" \
    --region "${REGION}" >/dev/null 2>&1
}

saida() {
  aws cloudformation describe-stacks \
    --stack-name "$1" \
    --region "${REGION}" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" \
    --output text
}

# O cofre só pode ser excluído sem pontos de recuperação
limpar_backups() {
  local vault
  vault="$(saida "${STACK_BACKUP}" BackupVaultName)"

  if [[ -z "${vault}" || "${vault}" == "None" ]]; then
    return 0
  fi

  local pontos=()
  read -r -a pontos <<< "$(aws backup list-recovery-points-by-backup-vault \
    --backup-vault-name "${vault}" \
    --region "${REGION}" \
    --query 'RecoveryPoints[].RecoveryPointArn' \
    --output text)"

  for arn in "${pontos[@]}"; do
    echo "Excluindo ponto de recuperação: ${arn}"
    aws backup delete-recovery-point \
      --backup-vault-name "${vault}" \
      --recovery-point-arn "${arn}" \
      --region "${REGION}"
  done

  for _ in $(seq 1 30); do
    local restantes
    restantes="$(aws backup list-recovery-points-by-backup-vault \
      --backup-vault-name "${vault}" \
      --region "${REGION}" \
      --query 'length(RecoveryPoints)' \
      --output text)"

    if [[ "${restantes}" == "0" ]]; then
      return 0
    fi

    echo "Aguardando exclusão dos pontos de recuperação (${restantes} restantes)..."
    sleep 10
  done
}

excluir_stack() {
  local stack="$1"

  if ! stack_existe "${stack}"; then
    echo "Stack ${stack} não encontrada - ignorando."
    return 0
  fi

  echo "Excluindo ${stack}..."
  aws cloudformation delete-stack --stack-name "${stack}" --region "${REGION}"
  aws cloudformation wait stack-delete-complete --stack-name "${stack}" --region "${REGION}"
  echo "${stack} excluída."
}

#--------------------------------------------------------------
# Execução
#--------------------------------------------------------------
echo "Stacks que serão excluídas (nesta ordem): ${ORDEM[*]}"

if [[ "${CONFIRMAR:-}" != "sim" ]]; then
  read -r -p "Digite 'sim' para confirmar: " resposta

  if [[ "${resposta}" != "sim" ]]; then
    echo "Operação cancelada."
    exit 0
  fi
fi

bucket_logs=""
chave_logs=""

if stack_existe "${STACK_AUDITORIA}"; then
  bucket_logs="$(saida "${STACK_AUDITORIA}" CloudTrailBucket)"
  chave_logs="$(saida "${STACK_AUDITORIA}" CloudTrailKMSKeyArn)"
fi

for stack in "${ORDEM[@]}"; do
  if [[ "${stack}" == "${STACK_BACKUP}" ]] && stack_existe "${stack}"; then
    limpar_backups
  fi

  excluir_stack "${stack}"
done

echo
echo "Ambiente removido. Recursos mantidos intencionalmente:"

if [[ -n "${bucket_logs}" ]]; then
  echo "  - Bucket com os logs do CloudTrail: ${bucket_logs}"
  echo "  - Chave KMS dos logs: ${chave_logs}"
fi

echo "  - Key Pair '${KEY_NAME}' e bucket de templates '${BUCKET}'"
echo "Para removê-los definitivamente, siga a seção 7 do README (Procedimentos operacionais)."
