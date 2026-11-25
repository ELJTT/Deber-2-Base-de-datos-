-- ============================================================================
-- SMART INVENTORY - 04_anexo_sin_bloqueo.sql
-- Experimento comparativo: READ COMMITTED sin bloqueo vs. SELECT ... FOR UPDATE
-- Ejecutar después de 01_schema, 02_seed y 04_transactions.
-- ============================================================================

-- 1. Variante de control SIN bloqueo pesimista (solo para el experimento)
-- Idéntica a sp_reservar_fefo pero sin la cláusula FOR UPDATE OF el.
CREATE OR REPLACE PROCEDURE sp_reservar_fefo_sin_bloqueo(
    p_order_id BIGINT,
    p_line_no  INTEGER
)
    LANGUAGE plpgsql
AS $proc$
DECLARE
    v_sku_id        BIGINT;
    v_qty_pedida    INTEGER;
    v_ya_reservado  INTEGER;
    v_restante      INTEGER;
    v_asignar       INTEGER;
    rec_lote        RECORD;
BEGIN
    SELECT sku_id, qty_requested
    INTO v_sku_id, v_qty_pedida
    FROM detalle_pedido
    WHERE order_id = p_order_id
      AND line_no = p_line_no;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Línea de pedido no existe (order_id=%, line_no=%)', p_order_id, p_line_no;
    END IF;

    SELECT COALESCE(SUM(qty_reserved), 0)
    INTO v_ya_reservado
    FROM reserva
    WHERE order_id = p_order_id
      AND line_no = p_line_no
      AND estado IN ('ACTIVA', 'CONSUMIDA');

    v_restante := v_qty_pedida - v_ya_reservado;

    IF v_restante <= 0 THEN
        RAISE NOTICE 'La línea ya se encuentra cubierta al 100%%.';
        RETURN;
    END IF;

    -- Lectura SIN bloqueo: el saldo leído puede quedar desactualizado si otra sesión reserva en paralelo
    FOR rec_lote IN
        SELECT
            el.lot_id,
            el.location_id,
            l.lot_code,
            l.vence_en,
            (el.qty_on_hand - el.qty_reserved) AS disponible
        FROM existencia_lote el
                 JOIN lote l ON l.lot_id = el.lot_id
        WHERE l.sku_id = v_sku_id
          AND (l.vence_en IS NULL OR l.vence_en > CURRENT_DATE)
          AND (el.qty_on_hand - el.qty_reserved) > 0
        ORDER BY
            l.vence_en ASC NULLS LAST,
            l.recibido_en ASC,
            el.lot_id ASC,
            el.location_id ASC
        LOOP
            EXIT WHEN v_restante = 0;

            v_asignar := LEAST(rec_lote.disponible, v_restante);

            INSERT INTO reserva (order_id, line_no, lot_id, location_id, qty_reserved, estado)
            VALUES (p_order_id, p_line_no, rec_lote.lot_id, rec_lote.location_id, v_asignar, 'ACTIVA');

            UPDATE existencia_lote
            SET qty_reserved = qty_reserved + v_asignar
            WHERE lot_id = rec_lote.lot_id
              AND location_id = rec_lote.location_id;

            v_restante := v_restante - v_asignar;
        END LOOP;

    IF v_restante > 0 THEN
        RAISE EXCEPTION 'Stock insuficiente para SKU % (order_id=%, line_no=%). Faltaron % unidades. Se revierte la transacción.',
            v_sku_id, p_order_id, p_line_no, v_restante;
    END IF;

    UPDATE pedido
    SET estado = 'RESERVADO'
    WHERE order_id = p_order_id;
END;
$proc$;

-- ============================================================================
-- 2. PREPARACIÓN IDEMPOTENTE: tres SKUs independientes con el mismo stock
--    (lote vencido 50 u., LOT-A 6 u. vence en 5 días, LOT-B 6 u. vence en 20 días)
--    SKU-SINBLOQ-8 : pedidos de 8 y 8 u. -> sp_reservar_fefo_sin_bloqueo
--    SKU-SINBLOQ-4 : pedidos de 8 y 4 u. -> sp_reservar_fefo_sin_bloqueo
--    SKU-CONBLOQ-4 : pedidos de 8 y 4 u. -> sp_reservar_fefo (con FOR UPDATE)
-- ============================================================================
DO $setup_anexo$
    DECLARE
        v_cod     TEXT;
        v_qty_b   INTEGER;
        v_sku_id  BIGINT;
        v_ord_a   BIGINT;
        v_ord_b   BIGINT;
    BEGIN
        FOR v_cod, v_qty_b IN
            SELECT * FROM (VALUES ('SKU-SINBLOQ-8', 8), ('SKU-SINBLOQ-4', 4), ('SKU-CONBLOQ-4', 4)) AS t(cod, qty)
            LOOP
                IF EXISTS (SELECT 1 FROM producto WHERE sku_code = v_cod) THEN
                    CONTINUE;
                END IF;

                INSERT INTO producto (sku_code, nombre, unidad, stock_minimo, stock_objetivo, default_supplier_id)
                VALUES (v_cod, 'Ampolla Adrenalina 1mg (Test ' || v_cod || ')', 'CAJA', 10, 50, 2)
                RETURNING sku_id INTO v_sku_id;

                INSERT INTO lote (sku_id, lot_code, vence_en, recibido_en) VALUES
                    (v_sku_id, v_cod || '-EXP', CURRENT_DATE - INTERVAL '2 days',  CURRENT_DATE - INTERVAL '30 days'),
                    (v_sku_id, v_cod || '-A',   CURRENT_DATE + INTERVAL '5 days',  CURRENT_DATE - INTERVAL '15 days'),
                    (v_sku_id, v_cod || '-B',   CURRENT_DATE + INTERVAL '20 days', CURRENT_DATE - INTERVAL '10 days');

                INSERT INTO movimiento (lot_id, destino_location_id, tipo, cantidad, observacion)
                SELECT lot_id, 1, 'RECEPCION',
                       CASE WHEN lot_code LIKE '%-EXP' THEN 50 ELSE 6 END,
                       'Stock test anexo sin bloqueo'
                FROM lote WHERE sku_id = v_sku_id;

                INSERT INTO pedido (estado) VALUES ('PENDIENTE') RETURNING order_id INTO v_ord_a;
                INSERT INTO pedido (estado) VALUES ('PENDIENTE') RETURNING order_id INTO v_ord_b;
                INSERT INTO detalle_pedido (order_id, line_no, sku_id, qty_requested) VALUES
                    (v_ord_a, 1, v_sku_id, 8),
                    (v_ord_b, 1, v_sku_id, v_qty_b);
            END LOOP;
    END;
$setup_anexo$;

-- Consultar los order_id a usar en cada escenario (A = pedido de 8, B = segundo pedido):
SELECT p.sku_code, dp.order_id, dp.qty_requested, ped.estado
FROM detalle_pedido dp
         JOIN producto p ON p.sku_id = dp.sku_id
         JOIN pedido ped ON ped.order_id = dp.order_id
WHERE p.sku_code IN ('SKU-SINBLOQ-8', 'SKU-SINBLOQ-4', 'SKU-CONBLOQ-4')
ORDER BY p.sku_code, dp.order_id;

-- ============================================================================
-- 3. GUÍA DE EJECUCIÓN (mismo procedimiento de dos consolas del 04, una vez por escenario)
--
-- ESCENARIO 1 - SKU-SINBLOQ-8 (B pide 8, sin bloqueo):
--   [CONSOLA 1]: BEGIN; CALL sp_reservar_fefo_sin_bloqueo(<ID_A>, 1);   -- sin COMMIT
--   [CONSOLA 2]: BEGIN; CALL sp_reservar_fefo_sin_bloqueo(<ID_B>, 1);   -- queda esperando en el UPDATE
--   [CONSOLA 1]: COMMIT;
--   [CONSOLA 2]: ERROR [23514]: ... violates check constraint "ck_existencia_reserved"; ROLLBACK;
--
-- ESCENARIO 2 - SKU-SINBLOQ-4 (B pide 4, sin bloqueo):
--   Mismos pasos con sp_reservar_fefo_sin_bloqueo.
--   [CONSOLA 2]: ERROR [23514]: ... "ck_existencia_reserved" (rechazo aunque LOT-B tiene 4 u. libres); ROLLBACK;
--
-- ESCENARIO 3 - SKU-CONBLOQ-4 (B pide 4, con FOR UPDATE):
--   Mismos pasos con sp_reservar_fefo.
--   [CONSOLA 2]: CALL termina sin error (reserva las 4 u. de LOT-B); COMMIT;
--
-- Verificación de saldos al final:
--   SELECT l.lot_code, el.qty_on_hand, el.qty_reserved
--   FROM existencia_lote el JOIN lote l ON l.lot_id = el.lot_id
--   WHERE l.lot_code LIKE 'SKU-%BLOQ%' ORDER BY l.lot_code;
-- ============================================================================
