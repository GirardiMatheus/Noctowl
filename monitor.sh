#!/bin/bash

# Noctowl - Server Resource Monitor
# Versão: 1.1
# Autor: Matheus Girardi
# Descrição: Monitora CPU, memória e disco, enviando alertas quando os limites são excedidos

# Carrega variáveis de ambiente
load_env() {
    local env_file="${1:-.env}"
    
    if [ -f "$env_file" ]; then
        # Exporta apenas variáveis que começam com NOCTOWL_
        while IFS= read -r line; do
            if [[ $line == NOCTOWL_* ]] && [[ $line != \#* ]]; then
                export "$line"
            fi
        done < "$env_file"
    else
        echo "Arquivo .env não encontrado. Usando valores padrão."
    fi
}

# Configura valores padrão
set_defaults() {
    # Limites
    export NOCTOWL_ALERT_CPU=${NOCTOWL_ALERT_CPU:-80}
    export NOCTOWL_ALERT_MEM=${NOCTOWL_ALERT_MEM:-80}
    export NOCTOWL_ALERT_DISK=${NOCTOWL_ALERT_DISK:-90}
    
    # Notificações
    export NOCTOWL_EMAIL_ENABLED=${NOCTOWL_EMAIL_ENABLED:-false}
    export NOCTOWL_SLACK_ENABLED=${NOCTOWL_SLACK_ENABLED:-false}
    export NOCTOWL_TELEGRAM_ENABLED=${NOCTOWL_TELEGRAM_ENABLED:-false}
    
    # Logging
    export NOCTOWL_LOG_ENABLED=${NOCTOWL_LOG_ENABLED:-true}
    export NOCTOWL_LOG_FILE=${NOCTOWL_LOG_FILE:-"/tmp/noctowl.log"}
}

# Função para log
log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Log to console
    echo "[$timestamp] $message"
    
    # Log to file if enabled and path is valid
    if [ "$NOCTOWL_LOG_ENABLED" = "true" ] && [ -n "$NOCTOWL_LOG_FILE" ]; then
        # Create directory if it doesn't exist
        local log_dir=$(dirname "$NOCTOWL_LOG_FILE")
        mkdir -p "$log_dir" 2>/dev/null
        
        # Create file if it doesn't exist
        touch "$NOCTOWL_LOG_FILE" 2>/dev/null || {
            echo "[$timestamp] WARNING: Failed to create log file at $NOCTOWL_LOG_FILE" >&2
            return
        }
        
        echo "[$timestamp] $message" >> "$NOCTOWL_LOG_FILE"
    fi
}

# Função para enviar alertas
send_alert() {
    local message="$1"
    local subject="[Noctowl Alert] $2"
    
    log "ALERTA: $subject - $message"
    
    # Envia por e-mail se habilitado
    if [ "$NOCTOWL_EMAIL_ENABLED" = "true" ] && [ -n "$NOCTOWL_EMAIL_TO" ]; then
        echo "$message" | mail -s "$subject" "$NOCTOWL_EMAIL_TO" && \
        log "Alerta enviado por e-mail para $NOCTOWL_EMAIL_TO" || \
        log "Falha ao enviar alerta por e-mail"
    fi
    
    # Envia para Slack se habilitado
    if [ "$NOCTOWL_SLACK_ENABLED" = "true" ] && [ -n "$NOCTOWL_SLACK_WEBHOOK" ]; then
        curl -X POST -H 'Content-type: application/json' \
        --data "{\"text\":\"$subject\n$message\"}" "$NOCTOWL_SLACK_WEBHOOK" && \
        log "Alerta enviado para Slack" || \
        log "Falha ao enviar alerta para Slack"
    fi
    
    # Envia para Telegram se habilitado
    if [ "$NOCTOWL_TELEGRAM_ENABLED" = "true" ] && \
        [ -n "$NOCTOWL_TELEGRAM_BOT_TOKEN" ] && \
        [ -n "$NOCTOWL_TELEGRAM_CHAT_ID" ]; then
        curl -s -X POST "https://api.telegram.org/bot$NOCTOWL_TELEGRAM_BOT_TOKEN/sendMessage" \
        -d chat_id="$NOCTOWL_TELEGRAM_CHAT_ID" \
        -d text="$subject\n$message" && \
        log "Alerta enviado para Telegram" || \
        log "Falha ao enviar alerta para Telegram"
    fi
}

# Monitoramento de CPU
check_cpu() {
    local cpu_usage
    
    # Verifica qual comando está disponível
    if command -v mpstat &> /dev/null; then
        cpu_usage=$(mpstat 1 1 | awk '/Average:/ {printf "%.0f", 100 - $NF}')
    elif command -v top &> /dev/null; then
        cpu_usage=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{printf "%.0f", 100 - $1}')
    else
        log "ERRO: Nenhum comando disponível para verificar CPU (top ou mpstat)"
        return 1
    fi
    
    if [ "$cpu_usage" -ge "$NOCTOWL_ALERT_CPU" ]; then
        send_alert "Uso de CPU está em ${cpu_usage}% (Limite: ${NOCTOWL_ALERT_CPU}%)" "Alerta de CPU"
        return 2
    fi
    
    log "Uso de CPU: ${cpu_usage}% (OK)"
    return 0
}

# Monitoramento de Memória
check_memory() {
    local mem_info
    local total_mem
    local free_mem
    local used_mem
    local mem_percent
    
    mem_info=$(free -m | awk '/Mem:/ {print $2,$3,$4,$6}')
    total_mem=$(echo $mem_info | awk '{print $1}')
    used_mem=$(echo $mem_info | awk '{print $2}')
    free_mem=$(echo $mem_info | awk '{print $3}')
    buffers_cache=$(echo $mem_info | awk '{print $4}')
    
    # Calcula memória realmente usada (considerando cache/buffers como disponível)
    actual_used=$(( used_mem - (buffers_cache > used_mem ? used_mem : buffers_cache) ))
    mem_percent=$(( (actual_used * 100 + total_mem/2) / total_mem ))
    
    if (( total_mem == 0 )); then
        log "ERRO: Não foi possível determinar a memória total"
        return 1
    fi

    if [ "$mem_percent" -ge "$NOCTOWL_ALERT_MEM" ]; then
        send_alert "Uso de memória está em ${mem_percent}% (${actual_used}MB de ${total_mem}MB) (Limite: ${NOCTOWL_ALERT_MEM}%)" "Alerta de Memória"
        return 2
    fi
    
    log "Memória: ${mem_percent}% (${actual_used}MB de ${total_mem}MB) [Buffers/Cache: ${buffers_cache}MB] (OK)"
    return 0
}

# Monitoramento de Disco
check_disk() {
    local disk_usage
    local alert=0
    local message=""
    
    # Verifica todas as partições, exceto tmpfs, squashfs e outras especiais
    while read -r line; do
        partition=$(echo "$line" | awk '{print $1}')
        percent=$(echo "$line" | awk '{print $5}' | cut -d'%' -f1)
        mount_point=$(echo "$line" | awk '{print $6}')
        
        if [ "$percent" -ge "$NOCTOWL_ALERT_DISK" ]; then
            message="${message}Partição $partition ($mount_point) está com ${percent}% de uso\n"
            alert=1
        fi
    done < <(df -h | grep -vE 'tmpfs|squashfs|udev|Filesystem')
    
    if [ $alert -eq 1 ]; then
        send_alert "$message" "Alerta de Espaço em Disco"
        return 2
    fi
    
    log "Uso de disco verificado (OK)"
    return 0
}

# Função principal
main() {
    log "Iniciando monitoramento Noctowl"
    log "===================================="
    
    # Carrega configurações
    load_env "$(dirname "$0")/.env"
    set_defaults
    
    # Executa verificações
    check_cpu
    check_memory
    check_disk
    
    log "===================================="
    log "Monitoramento Noctowl concluído"
}

# Executa o script
main "$@"