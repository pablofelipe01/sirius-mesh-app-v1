# Tarea: Integrar Airtable en el Gateway Mesh para registro de visitantes

## Contexto

La app **Sirius Porteria** (Flutter) maneja solicitudes de visitantes via Meshtastic BLE. El flujo actual es:

1. **Portero** envia solicitud `VISITA|nombre|motivo|area` al **Supervisor**
2. **Supervisor** responde `APROBADO|supervisor|comentario` al **Portero**

Esto ya funciona, pero los registros solo existen en memoria. Necesitamos persistir un historial de entrada/salida en **Airtable**.

## Que ya hicimos (Flutter - NO necesitas tocar esto)

La app Flutter ya fue modificada para enviar dos nuevos tipos de mensaje DM al gateway:

- `REGISTRO|STATUS|nombre|motivo|area|supervisor|comentario` — se envia cuando el supervisor responde una solicitud
- `SALIDA|nombre` — se envia cuando el portero registra la salida del visitante

Estos mensajes llegan como **DM directo** al nodo gateway (Mission Pack, `0x9ea29bc4`).

## Tu tarea: Modificar `mesh_gateway_with_agro.py`

El archivo esta en `/home/pi/agro_gateway/mesh_gateway_with_agro.py`.

### 1. Agregar configuracion Airtable

Despues de las constantes AGRO (`AGRO_SHEET_NAME`), agregar:

```python
# Configuracion Airtable - Registro de Visitantes
AIRTABLE_API_TOKEN = os.getenv('AIRTABLE_API_TOKEN', '')
AIRTABLE_BASE_ID = 'TU_BASE_ID'
AIRTABLE_TABLE_NAME = 'Registro Visitantes'
```

### 2. Agregar variable global

Despues de `agro_sheets_client`, agregar:

```python
pending_visits = {}  # {visitor_name_lower: airtable_record_id}
```

### 3. Agregar dos funciones nuevas

#### `handle_registro_message(text, from_id, from_num)`

- Parsea: `REGISTRO|STATUS|nombre|motivo|area|supervisor|comentario` (split por `|`, minimo 7 partes)
- POST a `https://api.airtable.com/v0/{AIRTABLE_BASE_ID}/{AIRTABLE_TABLE_NAME}` con header `Authorization: Bearer {AIRTABLE_API_TOKEN}`
- Body JSON con `fields`:
  - `Nombre Visitante`: nombre
  - `Motivo`: motivo
  - `Area`: area
  - `Fecha Solicitud`: datetime.now().isoformat()
  - `Estado`: status (APROBADO/NEGADO/PENDIENTE)
  - `Supervisor`: supervisor
  - `Comentario`: comentario
  - `Nodo Origen`: str(from_id)
  - `Hora Entrada`: datetime.now().isoformat() — **solo si status == 'APROBADO'**
- Si el POST es exitoso (200/201):
  - Guardar `pending_visits[nombre.lower()] = record['id']` (solo si APROBADO)
  - Enviar confirmacion al supervisor: `send_private_message(interface_global, from_num, f"REGISTRO_OK|{nombre}")`
- Si falla: enviar `REGISTRO_ERROR|nombre|mensaje_error`
- Patron identico a `handle_siembra_message` / `save_siembra_to_sheets`

#### `handle_salida_message(text, from_id, from_num)`

- Parsea: `SALIDA|nombre` (split por `|`, minimo 2 partes)
- Busca `record_id = pending_visits.get(nombre.lower())`
- Si no existe: enviar `SALIDA_ERROR|nombre|No se encontro visita activa`
- PATCH a `https://api.airtable.com/v0/{AIRTABLE_BASE_ID}/{AIRTABLE_TABLE_NAME}/{record_id}` con `fields: {'Hora Salida': datetime.now().isoformat()}`
- Si exitoso: borrar de `pending_visits`, enviar `SALIDA_OK|nombre`
- Si falla: enviar `SALIDA_ERROR|nombre|mensaje_error`

### 4. Agregar routing en `process_mesh_message()`

Despues del check de `SIEMBRA|` y **antes** de `@familia`, agregar:

```python
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
```

**Importante:** Solo procesar si `is_direct_to_me` es True (son DMs al gateway, no mensajes publicos).

## Tabla Airtable (ya creada)

| Campo | Tipo |
|-------|------|
| Nombre Visitante | Single line text |
| Motivo | Single line text |
| Area | Single line text |
| Fecha Solicitud | Date (con hora) |
| Nodo Origen | Single line text |
| Estado | Single select (APROBADO/NEGADO/PENDIENTE) |
| Supervisor | Single line text |
| Comentario | Long text |
| Hora Entrada | Date (con hora) |
| Hora Salida | Date (con hora) |

## Archivo de referencia

En `gateway/airtable_patch.py` (en este mismo repo) tienes las funciones completas ya escritas como referencia. Puedes copiar el codigo de ahi e integrarlo en el gateway.

## Dependencias

- `requests` — ya esta importado en el gateway
- `urllib.parse` — stdlib, para URL-encode del nombre de tabla
- No se necesitan dependencias nuevas

## Configuracion requerida

```bash
export AIRTABLE_API_TOKEN='pat_XXXXXXXXX'
```

Y en el codigo, actualizar `AIRTABLE_BASE_ID` con el ID real de la base de Airtable (formato `appXXXXXXXXXXXXXX`).

## Verificacion

1. Reiniciar gateway
2. Desde la app Flutter, enviar solicitud y aprobarla
3. Verificar que aparezca el registro en Airtable con hora de entrada
4. Registrar salida desde la app
5. Verificar que se actualice la hora de salida en Airtable
