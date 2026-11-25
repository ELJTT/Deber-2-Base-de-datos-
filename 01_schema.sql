-- ============================================================================
-- SMART INVENTORY - 01_schema.sql
-- Motor: PostgreSQL 16+
-- Descripción: Esquema relacional normalizado (3FN/BCNF), restricciones de
--              integridad y triggers de consistencia Kardex <-> Existencias.
-- ============================================================================

DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public;

-- ----------------------------------------------------------------------------
-- 1. CATÁLOGO Y ALMACÉN
-- ----------------------------------------------------------------------------

CREATE TABLE bodega (
                        warehouse_id BIGINT GENERATED ALWAYS AS IDENTITY,
                        codigo       VARCHAR(20)  NOT NULL,
                        nombre       VARCHAR(100) NOT NULL,
                        activo       BOOLEAN      NOT NULL DEFAULT TRUE,
                        CONSTRAINT pk_bodega PRIMARY KEY (warehouse_id),
                        CONSTRAINT uq_bodega_codigo UNIQUE (codigo)
);

CREATE TABLE ubicacion (
                           location_id  BIGINT GENERATED ALWAYS AS IDENTITY,
                           warehouse_id BIGINT      NOT NULL,
                           codigo       VARCHAR(30) NOT NULL,
                           zona         VARCHAR(40) NOT NULL,
                           tipo         VARCHAR(20) NOT NULL,
                           CONSTRAINT pk_ubicacion PRIMARY KEY (location_id),
                           CONSTRAINT fk_ubicacion_bodega FOREIGN KEY (warehouse_id)
                               REFERENCES bodega (warehouse_id) ON DELETE RESTRICT ON UPDATE CASCADE,
                           CONSTRAINT uq_ubicacion_bodega_codigo UNIQUE (warehouse_id, codigo),
                           CONSTRAINT ck_ubicacion_tipo CHECK (
                               tipo IN ('RECEPCION', 'ALMACENAJE', 'PICKING', 'DESPACHO', 'MERMA')
                               )
);

CREATE TABLE proveedor (
                           supplier_id BIGINT GENERATED ALWAYS AS IDENTITY,
                           codigo      VARCHAR(20)  NOT NULL,
                           nombre      VARCHAR(120) NOT NULL,
                           activo      BOOLEAN      NOT NULL DEFAULT TRUE,
                           CONSTRAINT pk_proveedor PRIMARY KEY (supplier_id),
                           CONSTRAINT uq_proveedor_codigo UNIQUE (codigo)
);

CREATE TABLE producto (
                          sku_id              BIGINT GENERATED ALWAYS AS IDENTITY,
                          sku_code            VARCHAR(30)  NOT NULL,
                          nombre              VARCHAR(150) NOT NULL,
                          unidad              VARCHAR(15)  NOT NULL DEFAULT 'UND',
                          stock_minimo        INTEGER      NOT NULL DEFAULT 0,
                          stock_objetivo      INTEGER      NOT NULL DEFAULT 0,
                          default_supplier_id BIGINT       NULL,
                          activo              BOOLEAN      NOT NULL DEFAULT TRUE,
                          CONSTRAINT pk_producto PRIMARY KEY (sku_id),
                          CONSTRAINT uq_producto_sku_code UNIQUE (sku_code),
                          CONSTRAINT fk_producto_proveedor FOREIGN KEY (default_supplier_id)
                              REFERENCES proveedor (supplier_id) ON DELETE RESTRICT ON UPDATE CASCADE,
                          CONSTRAINT ck_producto_stock_min CHECK (stock_minimo >= 0),
                          CONSTRAINT ck_producto_stock_obj CHECK (stock_objetivo >= stock_minimo)
);

CREATE TABLE lote (
                      lot_id      BIGINT GENERATED ALWAYS AS IDENTITY,
                      sku_id      BIGINT      NOT NULL,
                      lot_code    VARCHAR(40) NOT NULL,
                      vence_en    DATE        NULL,
                      recibido_en DATE        NOT NULL DEFAULT CURRENT_DATE,
                      CONSTRAINT pk_lote PRIMARY KEY (lot_id),
                      CONSTRAINT fk_lote_producto FOREIGN KEY (sku_id)
                          REFERENCES producto (sku_id) ON DELETE RESTRICT ON UPDATE CASCADE,
                      CONSTRAINT uq_lote_sku_code UNIQUE (sku_id, lot_code),
                      CONSTRAINT ck_lote_fechas CHECK (vence_en IS NULL OR vence_en >= recibido_en)
);

CREATE TABLE existencia_lote (
                                 lot_id       BIGINT  NOT NULL,
                                 location_id  BIGINT  NOT NULL,
                                 qty_on_hand  INTEGER NOT NULL DEFAULT 0,
                                 qty_reserved INTEGER NOT NULL DEFAULT 0,
                                 CONSTRAINT pk_existencia_lote PRIMARY KEY (lot_id, location_id),
                                 CONSTRAINT fk_existencia_lote FOREIGN KEY (lot_id)
                                     REFERENCES lote (lot_id) ON DELETE RESTRICT ON UPDATE CASCADE,
                                 CONSTRAINT fk_existencia_ubicacion FOREIGN KEY (location_id)
                                     REFERENCES ubicacion (location_id) ON DELETE RESTRICT ON UPDATE CASCADE,
                                 CONSTRAINT ck_existencia_on_hand CHECK (qty_on_hand >= 0),
                                 CONSTRAINT ck_existencia_reserved CHECK (
                                     qty_reserved >= 0 AND qty_reserved <= qty_on_hand
                                     )
);

-- ----------------------------------------------------------------------------
-- 2. REPOSICIÓN Y COMPRAS
-- ----------------------------------------------------------------------------

CREATE TABLE orden_compra (
                              po_id       BIGINT GENERATED ALWAYS AS IDENTITY,
                              supplier_id BIGINT      NOT NULL,
                              estado      VARCHAR(20) NOT NULL DEFAULT 'ABIERTA',
                              creado_en   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                              CONSTRAINT pk_orden_compra PRIMARY KEY (po_id),
                              CONSTRAINT fk_oc_proveedor FOREIGN KEY (supplier_id)
                                  REFERENCES proveedor (supplier_id) ON DELETE RESTRICT ON UPDATE CASCADE,
                              CONSTRAINT ck_oc_estado CHECK (
                                  estado IN ('ABIERTA', 'PARCIAL', 'COMPLETADA', 'CANCELADA')
                                  )
);

CREATE TABLE detalle_compra (
                                po_id          BIGINT         NOT NULL,
                                line_no        INTEGER        NOT NULL,
                                sku_id         BIGINT         NOT NULL,
                                qty_ordered    INTEGER        NOT NULL,
                                costo_unitario NUMERIC(12, 2) NOT NULL,
                                CONSTRAINT pk_detalle_compra PRIMARY KEY (po_id, line_no),
                                CONSTRAINT fk_det_compra_oc FOREIGN KEY (po_id)
                                    REFERENCES orden_compra (po_id) ON DELETE CASCADE ON UPDATE CASCADE,
                                CONSTRAINT fk_det_compra_producto FOREIGN KEY (sku_id)
                                    REFERENCES producto (sku_id) ON DELETE RESTRICT ON UPDATE CASCADE,
                                CONSTRAINT ck_det_compra_line CHECK (line_no > 0),
                                CONSTRAINT ck_det_compra_qty CHECK (qty_ordered > 0),
                                CONSTRAINT ck_det_compra_costo CHECK (costo_unitario >= 0)
);

-- ----------------------------------------------------------------------------
-- 3. PEDIDOS, RESERVAS FEFO Y KARDEX DE MOVIMIENTOS
-- ----------------------------------------------------------------------------

CREATE TABLE pedido (
                        order_id  BIGINT GENERATED ALWAYS AS IDENTITY,
                        estado    VARCHAR(20) NOT NULL DEFAULT 'PENDIENTE',
                        creado_en TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                        CONSTRAINT pk_pedido PRIMARY KEY (order_id),
                        CONSTRAINT ck_pedido_estado CHECK (
                            estado IN ('PENDIENTE', 'RESERVADO', 'PARCIAL', 'DESPACHADO', 'CANCELADO')
                            )
);

CREATE TABLE detalle_pedido (
                                order_id      BIGINT  NOT NULL,
                                line_no       INTEGER NOT NULL,
                                sku_id        BIGINT  NOT NULL,
                                qty_requested INTEGER NOT NULL,
                                CONSTRAINT pk_detalle_pedido PRIMARY KEY (order_id, line_no),
                                CONSTRAINT fk_det_pedido_pedido FOREIGN KEY (order_id)
                                    REFERENCES pedido (order_id) ON DELETE CASCADE ON UPDATE CASCADE,
                                CONSTRAINT fk_det_pedido_producto FOREIGN KEY (sku_id)
                                    REFERENCES producto (sku_id) ON DELETE RESTRICT ON UPDATE CASCADE,
                                CONSTRAINT ck_det_pedido_line CHECK (line_no > 0),
                                CONSTRAINT ck_det_pedido_qty CHECK (qty_requested > 0)
);

CREATE TABLE reserva (
                         reservation_id BIGINT GENERATED ALWAYS AS IDENTITY,
                         order_id       BIGINT      NOT NULL,
                         line_no        INTEGER     NOT NULL,
                         lot_id         BIGINT      NOT NULL,
                         location_id    BIGINT      NOT NULL,
                         qty_reserved   INTEGER     NOT NULL,
                         estado         VARCHAR(20) NOT NULL DEFAULT 'ACTIVA',
                         creado_en      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                         CONSTRAINT pk_reserva PRIMARY KEY (reservation_id),
                         CONSTRAINT fk_reserva_det_pedido FOREIGN KEY (order_id, line_no)
                             REFERENCES detalle_pedido (order_id, line_no) ON DELETE RESTRICT ON UPDATE CASCADE,
                         CONSTRAINT fk_reserva_existencia FOREIGN KEY (lot_id, location_id)
                             REFERENCES existencia_lote (lot_id, location_id) ON DELETE RESTRICT ON UPDATE CASCADE,
                         CONSTRAINT ck_reserva_qty CHECK (qty_reserved > 0),
                         CONSTRAINT ck_reserva_estado CHECK (
                             estado IN ('ACTIVA', 'CONSUMIDA', 'LIBERADA')
                             )
);

CREATE TABLE movimiento (
                            movement_id         BIGINT GENERATED ALWAYS AS IDENTITY,
                            lot_id              BIGINT      NOT NULL,
                            origen_location_id  BIGINT      NULL,
                            destino_location_id BIGINT      NULL,
                            tipo                VARCHAR(20) NOT NULL,
                            cantidad            INTEGER     NOT NULL,
                            fecha               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                            po_id               BIGINT      NULL,
                            po_line_no          INTEGER     NULL,
                            reservation_id      BIGINT      NULL,
                            ref_movement_id     BIGINT      NULL,
                            observacion         TEXT        NULL,
                            CONSTRAINT pk_movimiento PRIMARY KEY (movement_id),
                            CONSTRAINT fk_movimiento_lote FOREIGN KEY (lot_id)
                                REFERENCES lote (lot_id) ON DELETE RESTRICT ON UPDATE CASCADE,
                            CONSTRAINT fk_movimiento_origen FOREIGN KEY (origen_location_id)
                                REFERENCES ubicacion (location_id) ON DELETE RESTRICT ON UPDATE CASCADE,
                            CONSTRAINT fk_movimiento_destino FOREIGN KEY (destino_location_id)
                                REFERENCES ubicacion (location_id) ON DELETE RESTRICT ON UPDATE CASCADE,
                            CONSTRAINT fk_movimiento_det_compra FOREIGN KEY (po_id, po_line_no)
                                REFERENCES detalle_compra (po_id, line_no) ON DELETE RESTRICT ON UPDATE CASCADE,
                            CONSTRAINT fk_movimiento_reserva FOREIGN KEY (reservation_id)
                                REFERENCES reserva (reservation_id) ON DELETE RESTRICT ON UPDATE CASCADE,
                            CONSTRAINT fk_movimiento_ref FOREIGN KEY (ref_movement_id)
                                REFERENCES movimiento (movement_id) ON DELETE RESTRICT ON UPDATE CASCADE,
                            CONSTRAINT ck_movimiento_tipo CHECK (
                                tipo IN ('RECEPCION', 'DESPACHO', 'TRANSFERENCIA', 'AJUSTE_POS', 'AJUSTE_NEG', 'MERMA', 'COMPENSACION')
                                ),
                            CONSTRAINT ck_movimiento_cantidad CHECK (cantidad > 0),
                            CONSTRAINT ck_movimiento_ubicaciones CHECK (
                                (tipo IN ('RECEPCION', 'AJUSTE_POS') AND origen_location_id IS NULL AND destino_location_id IS NOT NULL)
                                    OR (tipo IN ('DESPACHO', 'AJUSTE_NEG', 'MERMA') AND origen_location_id IS NOT NULL AND destino_location_id IS NULL)
                                    OR (tipo = 'TRANSFERENCIA' AND origen_location_id IS NOT NULL AND destino_location_id IS NOT NULL AND origen_location_id <> destino_location_id)
                                    OR (tipo = 'COMPENSACION' AND (origen_location_id IS NOT NULL OR destino_location_id IS NOT NULL)
                                    AND (origen_location_id IS NULL OR destino_location_id IS NULL OR origen_location_id <> destino_location_id))
                                ),
                            CONSTRAINT ck_movimiento_po_par CHECK (
                                (po_id IS NULL AND po_line_no IS NULL) OR (po_id IS NOT NULL AND po_line_no IS NOT NULL)
                                ),
                            CONSTRAINT ck_movimiento_po_tipo CHECK (
                                po_id IS NULL OR tipo IN ('RECEPCION', 'COMPENSACION')
                                ),
                            CONSTRAINT ck_movimiento_res_tipo CHECK (
                                reservation_id IS NULL OR tipo IN ('DESPACHO', 'COMPENSACION')
                                ),
                            CONSTRAINT ck_movimiento_comp_ref CHECK (
                                (tipo = 'COMPENSACION' AND ref_movement_id IS NOT NULL)
                                    OR (tipo <> 'COMPENSACION' AND ref_movement_id IS NULL)
                                )
);

-- ----------------------------------------------------------------------------
-- 4. TRIGGERS DE INTEGRIDAD E INMUTABILIDAD DEL KARDEX
-- ----------------------------------------------------------------------------

DROP TRIGGER IF EXISTS trg_movimiento_inmutable ON movimiento;

CREATE OR REPLACE FUNCTION fn_bloquear_mutacion_movimiento()
    RETURNS TRIGGER
    LANGUAGE plpgsql
AS $func$
BEGIN
    RAISE EXCEPTION 'Operación prohibida: el historial de MOVIMIENTO es inmutable (movement_id=%). Registre un movimiento de tipo COMPENSACION.', OLD.movement_id;
END;
$func$;

CREATE TRIGGER trg_movimiento_inmutable
    BEFORE UPDATE OR DELETE ON movimiento
    FOR EACH ROW
EXECUTE FUNCTION fn_bloquear_mutacion_movimiento();

DROP TRIGGER IF EXISTS trg_movimiento_sync_existencia ON movimiento;

CREATE OR REPLACE FUNCTION fn_sincronizar_existencia_desde_movimiento()
    RETURNS TRIGGER
    LANGUAGE plpgsql
AS $func$
DECLARE
    v_res_estado VARCHAR(20);
    v_res_qty    INTEGER;
BEGIN
    -- Entrada en ubicación destino (RECEPCION, AJUSTE_POS, destino de TRANSFERENCIA o COMPENSACION)
    IF NEW.destino_location_id IS NOT NULL THEN
        INSERT INTO existencia_lote (lot_id, location_id, qty_on_hand, qty_reserved)
        VALUES (NEW.lot_id, NEW.destino_location_id, NEW.cantidad, 0)
        ON CONFLICT (lot_id, location_id)
            DO UPDATE SET qty_on_hand = existencia_lote.qty_on_hand + EXCLUDED.qty_on_hand;
    END IF;

    -- Salida desde ubicación origen (DESPACHO, AJUSTE_NEG, MERMA, origen de TRANSFERENCIA o COMPENSACION)
    IF NEW.origen_location_id IS NOT NULL THEN
        IF NEW.tipo = 'DESPACHO' AND NEW.reservation_id IS NOT NULL THEN
            SELECT estado, qty_reserved
            INTO v_res_estado, v_res_qty
            FROM reserva
            WHERE reservation_id = NEW.reservation_id
              AND lot_id = NEW.lot_id
              AND location_id = NEW.origen_location_id
                FOR UPDATE;

            IF NOT FOUND OR v_res_estado <> 'ACTIVA' OR v_res_qty <> NEW.cantidad THEN
                RAISE EXCEPTION 'Reserva inválida o no activa para despacho (reservation_id=%)', NEW.reservation_id;
            END IF;

            UPDATE existencia_lote
            SET qty_on_hand  = qty_on_hand - NEW.cantidad,
                qty_reserved = qty_reserved - NEW.cantidad
            WHERE lot_id = NEW.lot_id
              AND location_id = NEW.origen_location_id;

            UPDATE reserva
            SET estado = 'CONSUMIDA'
            WHERE reservation_id = NEW.reservation_id;
        ELSE
            UPDATE existencia_lote
            SET qty_on_hand = qty_on_hand - NEW.cantidad
            WHERE lot_id = NEW.lot_id
              AND location_id = NEW.origen_location_id;
        END IF;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'No existe saldo en existencia_lote para lot_id=% y location_id=%', NEW.lot_id, NEW.origen_location_id;
        END IF;
    END IF;

    RETURN NEW;
END;
$func$;

CREATE TRIGGER trg_movimiento_sync_existencia
    AFTER INSERT ON movimiento
    FOR EACH ROW
EXECUTE FUNCTION fn_sincronizar_existencia_desde_movimiento();