#!/bin/bash
#==============================================================
# deploy.sh - Implantação da Infra Code Server (projeto-upskilling)
#
# Uso:
#   EMAIL=voce@exemplo.com ./deploy.sh              # todas as etapas
#   EMAIL=voce@exemplo.com ./deploy.sh rede ec2     # etapas escolhidas
#
# Etapas (ordem padrão):
#   templates rede ec2 auditoria monitoramento dashboard backup custos resumo
#
# Variáveis opcionais:
#   REGION, BUCKET, PROJETO, AMBIENTE, RESPONSAVEL, ORCAMENTO_USD,
#   EC2_MODELO, NOME_INSTANCIA, KEY_NAME, SSH_CIDR, ATUALIZAR_AMI=sim
#==============================================================
set -euo pipefail

#--------------------------------------------------------------
# Configuração
#--------------------------------------------------------------
REGION="${REGION:-sa-east-1}"
BUCKET="${BUCKET:-projeto-upskilling}"
PROJETO="${PROJETO:-projeto-upskilling}"
AMBIENTE="${AMBIENTE:-dev}"
RESPONSAVEL="${RESPONSAVEL:-c153824}"
EMAIL="${EMAIL:-}"
ORCAMENTO_USD="${ORCAMENTO_USD:-50}"
EC2_MODELO="${EC2_MODELO:-t3.medium}"
NOME_INSTANCIA="${NOME_INSTANCIA:-codeserver2}"
KEY_NAME="${KEY_NAME:-code-server}"
KEY_FILE="${HOME}/${KEY_NAME}.pem"
SSH_CIDR="${SSH_CIDR:-}"
AMI_SSM="/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"

# Rede e EC2 mantêm os nomes de stack já utilizados no projeto
STACK_REDE="infraContabil"
STACK_EC2="vscodeServer"
STACK_AUDITORIA="upsk-auditoria"
STACK_MONITORAMENTO="upsk-monitoramento"
STACK_DASHBOARD="upsk-dashboard"
STACK_BACKUP="upsk-backup"
STACK_CUSTOS="upsk-custos"

# Tags de stack: o CloudFormation propaga para todos os recursos
TAGS=(
  "Projeto=${PROJETO}"
  "Ambiente=${AMBIENTE}"
  "Responsavel=${RESPONSAVEL}"
  "CentroCusto=upskilling"
  "GerenciadoPor=CloudFormation"
)

ETAPAS_PADRAO=(templates rede ec2 auditoria monitoramento dashboard backup custos resumo)

cd "$(dirname "$0")"

#--------------------------------------------------------------
# Funções auxiliares
#--------------------------------------------------------------
titulo() {
  echo
  echo "=============================================================="
  echo "$1"
  echo "=============================================================="
}

stack_existe() {
  aws cloudformation describe-stacks \
    --stack-name "$1" \
    --region "${REGION}" >/dev/null 2>&1
}

# saida <stack> <OutputKey>
saida() {
  aws cloudformation describe-stacks \
    --stack-name "$1" \
    --region "${REGION}" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" \
    --output text
}

# Usa o template local; se não existir, baixa do bucket
template() {
  local caminho="$1"

  if [[ -f "${caminho}" ]]; then
    echo "${caminho}"
  else
    local destino="/tmp/${caminho//\//-}"
    aws s3 cp "s3://${BUCKET}/${caminho}" "${destino}" --region "${REGION}" >/dev/null
    echo "${destino}"
  fi
}

# deploy <stack> <template> [Parametro=Valor ...]
deploy() {
  local stack="$1"
  local arquivo="$2"
  shift 2

  titulo "Deploy: ${stack} (${arquivo})"

  local args=(
    --stack-name "${stack}"
    --template-file "$(template "${arquivo}")"
    --region "${REGION}"
    --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM
    --no-fail-on-empty-changeset
    --tags "${TAGS[@]}"
  )

  if [[ $# -gt 0 ]]; then
    args+=(--parameter-overrides "$@")
  fi

  aws cloudformation deploy "${args[@]}"
}

exigir_email() {
  if [[ -z "${EMAIL}" ]]; then
    echo "ERRO: a etapa '$1' exige um e-mail. Ex.: EMAIL=voce@exemplo.com ./deploy.sh" >&2
    exit 1
  fi
}

#--------------------------------------------------------------
# Etapa 1 - Bucket privado e upload dos templates
#--------------------------------------------------------------
etapa_templates() {
  titulo "Templates: s3://${BUCKET}"

  if ! aws s3api head-bucket --bucket "${BUCKET}" --region "${REGION}" >/dev/null 2>&1; then
    echo "Criando bucket privado ${BUCKET}..."

    if [[ "${REGION}" == "us-east-1" ]]; then
      aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}" >/dev/null
    else
      aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}" \
        --create-bucket-configuration LocationConstraint="${REGION}" >/dev/null
    fi

    aws s3api put-public-access-block --bucket "${BUCKET}" --region "${REGION}" \
      --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

    aws s3api put-bucket-encryption --bucket "${BUCKET}" --region "${REGION}" \
      --server-side-encryption-configuration \
      '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

    aws s3api put-bucket-versioning --bucket "${BUCKET}" --region "${REGION}" \
      --versioning-configuration Status=Enabled
  fi

  # O nome do bucket é global: um bucket em outra região quebraria os TemplateURL (<bucket>.s3.<REGION>)
  local regiao_bucket
  regiao_bucket="$(aws s3api head-bucket --bucket "${BUCKET}" --region "${REGION}" \
    --query BucketRegion --output text)"

  if [[ "${regiao_bucket}" != "None" && "${regiao_bucket}" != "${REGION}" ]]; then
    echo "ERRO: o bucket ${BUCKET} está na região ${regiao_bucket}, e não em ${REGION}." >&2
    echo "Use outro nome (ex.: BUCKET=meu-bucket-${REGION} ./deploy.sh) ou exclua o bucket antigo." >&2
    exit 1
  fi

  if [[ -f main.yaml ]]; then
    aws s3 sync . "s3://${BUCKET}/" --region "${REGION}" \
      --exclude "*" \
      --include "main.yaml" \
      --include "modules/*.yaml" \
      --include "EC2/*.yaml" \
      --include "extras/*.yaml"
  else
    echo "Templates locais não encontrados - usando os que já estão no bucket."
  fi
}

#--------------------------------------------------------------
# Etapa 2 - Rede (main.yaml + nested stacks de modules/)
#--------------------------------------------------------------
etapa_rede() {
  if [[ -z "${SSH_CIDR}" ]]; then
    local ip
    ip="$(curl -fsS --max-time 10 https://checkip.amazonaws.com || true)"

    if [[ ! "${ip}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
      echo "ERRO: não foi possível detectar o IP público. Defina SSH_CIDR (ex.: SSH_CIDR=200.10.20.30/32)." >&2
      exit 1
    fi

    SSH_CIDR="${ip}/32"
  fi

  echo "Porta 22 liberada somente para: ${SSH_CIDR}"

  deploy "${STACK_REDE}" "main.yaml" \
    BucketS3="${BUCKET}.s3.${REGION}" \
    NameVPC="codeserver" \
    SSHCidr="${SSH_CIDR}" \
    Projeto="${PROJETO}"
}

#--------------------------------------------------------------
# Etapa 3 - Key Pair + EC2 code-server
#--------------------------------------------------------------
garantir_key_pair() {
  titulo "Key Pair: ${KEY_NAME}"

  if aws ec2 describe-key-pairs \
    --key-names "${KEY_NAME}" \
    --region "${REGION}" \
    >/dev/null 2>&1
  then
    echo "Key Pair '${KEY_NAME}' já existe na região ${REGION}."

    if [[ -f "${KEY_FILE}" ]]; then
      chmod 400 "${KEY_FILE}"
      echo "Chave privada disponível em: ${KEY_FILE}"
    else
      echo "ATENÇÃO: o arquivo ${KEY_FILE} não existe."
      echo "A AWS não permite recuperar novamente a chave privada de um Key Pair existente."
      echo "Use o SSM Session Manager (output ComandoSSM) para acessar a instância."
    fi
  else
    echo "Criando Key Pair '${KEY_NAME}'..."

    if [[ -f "${KEY_FILE}" ]]; then
      mv "${KEY_FILE}" "${KEY_FILE}.$(date +%Y%m%d%H%M%S).bak"
      echo "Arquivo de chave antigo preservado com sufixo .bak"
    fi

    (
      umask 077
      aws ec2 create-key-pair \
        --key-name "${KEY_NAME}" \
        --key-type rsa \
        --region "${REGION}" \
        --tag-specifications "ResourceType=key-pair,Tags=[{Key=Projeto,Value=${PROJETO}},{Key=Ambiente,Value=${AMBIENTE}}]" \
        --query 'KeyMaterial' \
        --output text > "${KEY_FILE}"
    )

    chmod 400 "${KEY_FILE}"

    echo "Key Pair criado."
    echo "Chave privada salva em: ${KEY_FILE}"
  fi
}

etapa_ec2() {
  garantir_key_pair

  # A AMI fica fixa após a criação: uma AMI nova substituiria a instância
  local ami=""

  if [[ "${ATUALIZAR_AMI:-nao}" != "sim" ]] && stack_existe "${STACK_EC2}"; then
    ami="$(aws cloudformation describe-stacks \
      --stack-name "${STACK_EC2}" \
      --region "${REGION}" \
      --query "Stacks[0].Parameters[?ParameterKey=='AmiId'].ParameterValue" \
      --output text)"
  fi

  if [[ -z "${ami}" || "${ami}" == "None" ]]; then
    ami="$(aws ssm get-parameter \
      --name "${AMI_SSM}" \
      --region "${REGION}" \
      --query 'Parameter.Value' \
      --output text)"
  fi

  echo "AMI: ${ami}"

  deploy "${STACK_EC2}" "EC2/codeserver.yaml" \
    EC2Modelo="${EC2_MODELO}" \
    KeyName="${KEY_NAME}" \
    NomeInstancia="${NOME_INSTANCIA}" \
    AmiId="${ami}"
}

#--------------------------------------------------------------
# Etapas 4 a 8 - Governança (extras/)
#--------------------------------------------------------------
etapa_auditoria() {
  deploy "${STACK_AUDITORIA}" "extras/auditoria-cloudtrail.yaml" \
    TrailName="infra-cloudtrail"
}

etapa_monitoramento() {
  deploy "${STACK_MONITORAMENTO}" "extras/monitoramento-cloudwatch.yaml" \
    Environment="${AMBIENTE}" \
    NotificationEmail="${EMAIL}"

  echo "Confirme a assinatura do SNS enviada para ${EMAIL} para receber os alertas."
}

etapa_dashboard() {
  local alarmes=""

  if stack_existe "${STACK_MONITORAMENTO}"; then
    alarmes="$(saida "${STACK_MONITORAMENTO}" AlarmArns)"
  fi

  deploy "${STACK_DASHBOARD}" "extras/dashboard.yaml" \
    Environment="${AMBIENTE}" \
    AlarmArns="${alarmes}"
}

etapa_backup() {
  deploy "${STACK_BACKUP}" "extras/backup.yaml" \
    Environment="${AMBIENTE}" \
    RetencaoDias="7"
}

etapa_custos() {
  deploy "${STACK_CUSTOS}" "extras/custos-budget.yaml" \
    Environment="${AMBIENTE}" \
    NotificationEmail="${EMAIL}" \
    ValorMensalUSD="${ORCAMENTO_USD}"
}

#--------------------------------------------------------------
# Resumo - informações de acesso
#--------------------------------------------------------------
etapa_resumo() {
  titulo "Resumo"

  if stack_existe "${STACK_EC2}"; then
    echo "code-server : $(saida "${STACK_EC2}" CodeServerURL)"
    echo "Senha       : $(saida "${STACK_EC2}" ComandoSenha)"
    echo "SSH         : $(saida "${STACK_EC2}" ComandoSSH)"
    echo "SSM         : $(saida "${STACK_EC2}" ComandoSSM)"
  fi

  if stack_existe "${STACK_DASHBOARD}"; then
    echo "Dashboard   : $(saida "${STACK_DASHBOARD}" SecurityDashboardURL)"
  fi

  echo "Inventário  : aws resource-groups list-group-resources --group ${PROJETO}-inventario --region ${REGION}"
}

#--------------------------------------------------------------
# Execução
#--------------------------------------------------------------
ETAPAS=("$@")

if [[ ${#ETAPAS[@]} -eq 0 ]]; then
  ETAPAS=("${ETAPAS_PADRAO[@]}")
fi

for etapa in "${ETAPAS[@]}"; do
  case "${etapa}" in
    templates|rede|ec2|auditoria|dashboard|backup|resumo) ;;
    monitoramento|custos) exigir_email "${etapa}" ;;
    *)
      echo "Etapa inválida: ${etapa}. Opções: ${ETAPAS_PADRAO[*]}" >&2
      exit 1
      ;;
  esac
done

for etapa in "${ETAPAS[@]}"; do
  "etapa_${etapa}"
done
