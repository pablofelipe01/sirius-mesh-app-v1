"""
Airtable Integration Patch for mesh_gateway_with_agro.py
========================================================

Instrucciones:
1. Copiar este archivo al Pi: scp airtable_patch.py pi@meshgateway:/home/pi/agro_gateway/
2. En el Pi, agregar los cambios al gateway principal (ver instrucciones abajo)
3. Configurar variable de entorno: export AIRTABLE_API_TOKEN='tu_token_aqui'
4. Configurar AIRTABLE_BASE_ID y AIRTABLE_TABLE_NAME abajo
5. Reiniciar el gateway

=== CAMBIOS NECESARIOS EN mesh_gateway_with_agro.py ===

1) Agregar después de las constantes AGRO (AGRO_SHEET_NAME):

    # Configuración Airtable - Registro de Visitantes
    AIRTABLE_API_TOKEN = os.getenv('AIRTABLE_API_TOKEN', '')
    AIRTABLE_BASE_ID = 'TU_BASE_ID'
    AIRTABLE_TABLE_NAME = 'Registro Visitantes'

2) Agregar variable global (después de agro_sheets_client):

    pending_visits = {}  # {visitor_name_lower: airtable_record_id}

3) Agregar funciones handle_registro_message y handle_salida_message (ver abajo)

4) Agregar routing en process_mesh_message() después de SIEMBRA| y antes de @familia:

    # REGISTRO visitantes (Airtable)
    if text.startswith('REGISTRO|') and is_direct_to_me:
        logging.info(f"📋 Mensaje REGISTRO detectado")
        handle_registro_message(text, from_id, from_num)
        return

    # SALIDA visitantes (Airtable)
    if text.startswith('SALIDA|') and is_direct_to_me:
        logging.info(f"🚪 Mensaje SALIDA detectado")
        handle_salida_message(text, from_id, from_num)
        return

"""

import os
import logging
import requests
from datetime import datetime

# ==================== CONFIGURACIÓN AIRTABLE ====================

AIRTABLE_API_TOKEN = os.getenv('AIRTABLE_API_TOKEN', '')
AIRTABLE_BASE_ID = 'TU_BASE_ID'  # Reemplazar con tu Base ID real
AIRTABLE_TABLE_NAME = 'Registro Visitantes'

# Tracking de visitas activas para registrar salida
pending_visits = {}  # {visitor_name_lower: airtable_record_id}


# ==================== FUNCIONES AIRTABLE ====================

def _airtable_headers():
    """Headers para requests a Airtable API"""
    return {
        'Authorization': f'Bearer {AIRTABLE_API_TOKEN}',
        'Content-Type': 'application/json',
    }


def _airtable_url():
    """URL base de la tabla en Airtable"""
    # URL-encode el nombre de la tabla por si tiene espacios
    import urllib.parse
    table_encoded = urllib.parse.quote(AIRTABLE_TABLE_NAME)
    return f'https://api.airtable.com/v0/{AIRTABLE_BASE_ID}/{table_encoded}'


def handle_registro_message(text, from_id, from_num):
    """
    Procesar mensaje REGISTRO de visitante y guardar en Airtable.
    Formato: REGISTRO|STATUS|nombre|motivo|area|supervisor|comentario
    """
    # Importar referencia global al interface (definida en el gateway principal)
    global interface_global, pending_visits

    try:
        parts = text.split('|')
        if len(parts) < 7:
            logging.error(f"✗ Formato REGISTRO inválido: {text}")
            send_private_message(interface_global, from_num,
                "✗ Error: Formato REGISTRO inválido")
            return

        status = parts[1]       # APROBADO, NEGADO, PENDIENTE
        nombre = parts[2]
        motivo = parts[3]
        area = parts[4]
        supervisor = parts[5]
        comentario = parts[6] if len(parts) > 6 else ''

        logging.info(f"📋 Registrando visitante: {nombre} - Estado: {status}")

        if not AIRTABLE_API_TOKEN:
            logging.error("✗ AIRTABLE_API_TOKEN no configurado")
            send_private_message(interface_global, from_num,
                f"REGISTRO_ERROR|{nombre}|Token Airtable no configurado")
            return

        now = datetime.now().isoformat()

        # Campos para Airtable
        fields = {
            'Nombre Visitante': nombre,
            'Motivo': motivo,
            'Area': area,
            'Fecha Solicitud': now,
            'Estado': status,
            'Supervisor': supervisor,
            'Comentario': comentario,
            'Nodo Origen': str(from_id),
        }

        # Solo registrar hora de entrada si fue aprobado
        if status == 'APROBADO':
            fields['Hora Entrada'] = now

        # POST a Airtable
        response = requests.post(
            _airtable_url(),
            headers=_airtable_headers(),
            json={'fields': fields},
            timeout=15,
        )

        if response.status_code in (200, 201):
            record = response.json()
            record_id = record.get('id', '')
            logging.info(f"✓ Registro Airtable creado: {record_id}")

            # Guardar para tracking de salida (solo si aprobado)
            if status == 'APROBADO':
                pending_visits[nombre.lower()] = record_id
                logging.info(f"✓ Visita activa registrada: {nombre.lower()} -> {record_id}")

            # Confirmar al supervisor
            send_private_message(interface_global, from_num,
                f"REGISTRO_OK|{nombre}")
            logging.info(f"✓ Confirmación enviada a {from_id}")

            # Publicar a MQTT si disponible
            try:
                publish_mqtt("visitantes/registro", {
                    "nombre": nombre,
                    "status": status,
                    "supervisor": supervisor,
                    "record_id": record_id,
                    "timestamp": now,
                })
            except Exception:
                pass

        else:
            logging.error(f"✗ Error Airtable: HTTP {response.status_code} - {response.text}")
            send_private_message(interface_global, from_num,
                f"REGISTRO_ERROR|{nombre}|Error Airtable: {response.status_code}")

    except Exception as e:
        logging.error(f"✗ Error en handle_registro_message: {e}")
        import traceback
        logging.error(traceback.format_exc())
        try:
            send_private_message(interface_global, from_num,
                f"REGISTRO_ERROR|Error interno: {str(e)[:50]}")
        except Exception:
            pass


def handle_salida_message(text, from_id, from_num):
    """
    Procesar mensaje SALIDA de visitante y actualizar Airtable.
    Formato: SALIDA|nombre
    """
    global interface_global, pending_visits

    try:
        parts = text.split('|')
        if len(parts) < 2:
            logging.error(f"✗ Formato SALIDA inválido: {text}")
            send_private_message(interface_global, from_num,
                "✗ Error: Formato SALIDA inválido")
            return

        nombre = parts[1]
        nombre_key = nombre.lower()

        logging.info(f"🚪 Registrando salida: {nombre}")

        if not AIRTABLE_API_TOKEN:
            logging.error("✗ AIRTABLE_API_TOKEN no configurado")
            send_private_message(interface_global, from_num,
                f"SALIDA_ERROR|{nombre}|Token Airtable no configurado")
            return

        # Buscar record_id en pending_visits
        record_id = pending_visits.get(nombre_key)

        if not record_id:
            logging.warning(f"⚠️ No se encontró visita activa para: {nombre}")
            send_private_message(interface_global, from_num,
                f"SALIDA_ERROR|{nombre}|No se encontro visita activa")
            return

        now = datetime.now().isoformat()

        # PATCH a Airtable
        patch_url = f"{_airtable_url()}/{record_id}"
        response = requests.patch(
            patch_url,
            headers=_airtable_headers(),
            json={'fields': {'Hora Salida': now}},
            timeout=15,
        )

        if response.status_code == 200:
            logging.info(f"✓ Hora de salida actualizada: {nombre} ({record_id})")

            # Remover de pending
            del pending_visits[nombre_key]

            # Confirmar al portero
            send_private_message(interface_global, from_num,
                f"SALIDA_OK|{nombre}")

            # Publicar a MQTT si disponible
            try:
                publish_mqtt("visitantes/salida", {
                    "nombre": nombre,
                    "record_id": record_id,
                    "hora_salida": now,
                })
            except Exception:
                pass

        else:
            logging.error(f"✗ Error Airtable PATCH: HTTP {response.status_code} - {response.text}")
            send_private_message(interface_global, from_num,
                f"SALIDA_ERROR|{nombre}|Error Airtable: {response.status_code}")

    except Exception as e:
        logging.error(f"✗ Error en handle_salida_message: {e}")
        import traceback
        logging.error(traceback.format_exc())
        try:
            send_private_message(interface_global, from_num,
                f"SALIDA_ERROR|Error interno: {str(e)[:50]}")
        except Exception:
            pass
