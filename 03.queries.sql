-- ============================================================================
-- SMART INVENTORY - 03_queries.sql
-- Las 8 consultas operativas y analíticas (incluye Window Functions)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- CONSULTA 1: Stock disponible por SKU, bodega y ubicación
-- Descuenta reservas vigentes e incluye SKUs con 0 stock (LEFT JOIN).
-- ----------------------------------------------------------------------------
SELECT
    p.sku_code,
    p.nombre AS producto,
    COALESCE(b.codigo, 'SIN_BODEGA') AS bodega,
    COALESCE(u.codigo, 'SIN_UBICACION') AS ubicacion,
    COALESCE(el.qty_on_hand, 0) AS stock_fisico,
    COALESCE(el.qty_reserved, 0) AS stock_reservado,
    COALESCE(el.qty_on_hand - el.qty_reserved, 0) AS stock_disponible
FROM producto p
         LEFT JOIN lote l ON l.sku_id = p.sku_id
         LEFT JOIN existencia_lote el ON el.lot_id = l.lot_id
         LEFT JOIN ubicacion u ON u.location_id = el.location_id
         LEFT JOIN bodega b ON b.warehouse_id = u.warehouse_id
WHERE p.activo = TRUE
ORDER BY p.sku_code, b.codigo NULLS LAST, u.codigo NULLS LAST;


-- ----------------------------------------------------------------------------
-- CONSULTA 2: Lotes próximos a vencer (parámetro configurable de días)
-- Separa los lotes ya vencidos de los próximos a vencer dentro de N días.
-- ----------------------------------------------------------------------------
WITH params AS (
    SELECT 30 AS dias_alerta
)
SELECT
    p.sku_code,
    p.nombre AS producto,
    l.lot_code,
    l.vence_en,
    (l.vence_en - CURRENT_DATE) AS dias_para_vencer,
    CASE
        WHEN l.vence_en IS NULL THEN 'SIN_VENCIMIENTO'
        WHEN l.vence_en <= CURRENT_DATE THEN 'VENCIDO'
        WHEN l.vence_en <= CURRENT_DATE + (SELECT dias_alerta FROM params) THEN 'PROXIMO_A_VENCER'
        ELSE 'VIGENTE'
        END AS estado_caducidad,
    COALESCE(SUM(el.qty_on_hand), 0) AS stock_fisico,
    COALESCE(SUM(el.qty_on_hand - el.qty_reserved), 0) AS stock_disponible
FROM lote l
         JOIN producto p ON p.sku_id = l.sku_id
         LEFT JOIN existencia_lote el ON el.lot_id = l.lot_id
WHERE l.vence_en IS NOT NULL
  AND l.vence_en <= CURRENT_DATE + (SELECT dias_alerta FROM params)
GROUP BY p.sku_code, p.nombre, l.lot_id, l.lot_code, l.vence_en
ORDER BY l.vence_en ASC;


-- ----------------------------------------------------------------------------
-- CONSULTA 3: Plan de picking FEFO (con Window Function SUM() OVER)
-- Excluye vencidos, ordena por vencimiento/recepción/código y corta al cubrir demanda.
-- ----------------------------------------------------------------------------
WITH params AS (
    SELECT 'SKU-VAC-01'::VARCHAR AS target_sku, 35 AS demanda_solicitada
),
     lotes_elegibles AS (
         SELECT
             p.sku_code,
             p.nombre AS producto,
             l.lot_id,
             l.lot_code,
             l.vence_en,
             l.recibido_en,
             b.codigo AS bodega,
             u.codigo AS ubicacion,
             (el.qty_on_hand - el.qty_reserved) AS disponible,
             SUM(el.qty_on_hand - el.qty_reserved) OVER (
                 PARTITION BY p.sku_id
                 ORDER BY l.vence_en ASC NULLS LAST, l.recibido_en ASC, l.lot_code ASC, el.location_id ASC
                 ) AS acumulado_disponible
         FROM existencia_lote el
                  JOIN lote l ON l.lot_id = el.lot_id
                  JOIN producto p ON p.sku_id = l.sku_id
                  JOIN ubicacion u ON u.location_id = el.location_id
                  JOIN bodega b ON b.warehouse_id = u.warehouse_id
                  CROSS JOIN params prm
         WHERE p.sku_code = prm.target_sku
           AND p.activo = TRUE
           AND (l.vence_en IS NULL OR l.vence_en > CURRENT_DATE)
           AND (el.qty_on_hand - el.qty_reserved) > 0
     )
SELECT
    le.sku_code,
    le.lot_code,
    le.vence_en,
    le.recibido_en,
    le.bodega,
    le.ubicacion,
    le.disponible,
    le.acumulado_disponible,
    GREATEST(
            0,
            LEAST(le.disponible, prm.demanda_solicitada - (le.acumulado_disponible - le.disponible))
    ) AS qty_asignar_fefo,
    CASE
        WHEN le.acumulado_disponible >= prm.demanda_solicitada THEN 'DEMANDA_CUBIERTA'
        ELSE 'PARCIAL_CONTINUA_SIGUIENTE_LOTE'
        END AS estado_cobertura
FROM lotes_elegibles le
         CROSS JOIN params prm
WHERE (le.acumulado_disponible - le.disponible) < prm.demanda_solicitada
ORDER BY le.vence_en ASC NULLS LAST, le.recibido_en ASC, le.lot_code ASC;


-- ----------------------------------------------------------------------------
-- CONSULTA 4: Productos bajo mínimo y sugerencia de compra
-- Posición = stock físico vigente + en órdenes abiertas - reservado.
-- ----------------------------------------------------------------------------
WITH stock_actual AS (
    SELECT
        l.sku_id,
        COALESCE(SUM(el.qty_on_hand), 0) AS qty_on_hand,
        COALESCE(SUM(el.qty_reserved), 0) AS qty_reserved
    FROM lote l
             JOIN existencia_lote el ON el.lot_id = l.lot_id
    WHERE l.vence_en IS NULL OR l.vence_en > CURRENT_DATE
    GROUP BY l.sku_id
),
     ordenes_abiertas AS (
         SELECT
             dc.sku_id,
             SUM(dc.qty_ordered - COALESCE(rec.qty_recibida, 0)) AS qty_en_transito
         FROM detalle_compra dc
                  JOIN orden_compra oc ON oc.po_id = dc.po_id
                  LEFT JOIN (
             SELECT po_id, po_line_no, SUM(cantidad) AS qty_recibida
             FROM movimiento
             WHERE tipo = 'RECEPCION'
             GROUP BY po_id, po_line_no
         ) rec ON rec.po_id = dc.po_id AND rec.po_line_no = dc.line_no
         WHERE oc.estado IN ('ABIERTA', 'PARCIAL')
         GROUP BY dc.sku_id
     )
SELECT
    p.sku_code,
    p.nombre AS producto,
    COALESCE(sa.qty_on_hand, 0) AS disponible_fisico,
    COALESCE(sa.qty_reserved, 0) AS reservado,
    COALESCE(oa.qty_en_transito, 0) AS en_ordenes_abiertas,
    (COALESCE(sa.qty_on_hand, 0) + COALESCE(oa.qty_en_transito, 0) - COALESCE(sa.qty_reserved, 0)) AS posicion_inventario,
    p.stock_minimo,
    p.stock_objetivo,
    GREATEST(
            0,
            p.stock_objetivo - (COALESCE(sa.qty_on_hand, 0) + COALESCE(oa.qty_en_transito, 0) - COALESCE(sa.qty_reserved, 0))
    ) AS sugerencia_compra,
    pr.codigo AS cod_proveedor,
    pr.nombre AS proveedor_sugerido
FROM producto p
         LEFT JOIN stock_actual sa ON sa.sku_id = p.sku_id
         LEFT JOIN ordenes_abiertas oa ON oa.sku_id = p.sku_id
         LEFT JOIN proveedor pr ON pr.supplier_id = p.default_supplier_id
WHERE p.activo = TRUE
  AND (COALESCE(sa.qty_on_hand, 0) + COALESCE(oa.qty_en_transito, 0) - COALESCE(sa.qty_reserved, 0)) < p.stock_minimo
ORDER BY sugerencia_compra DESC;


-- ----------------------------------------------------------------------------
-- CONSULTA 5: Trazabilidad completa de un pedido
-- Pedido -> líneas -> reservas -> lotes/ubicaciones -> movimientos.
-- ----------------------------------------------------------------------------
SELECT
    ped.order_id,
    ped.estado AS estado_pedido,
    ped.creado_en AS fecha_pedido,
    dp.line_no,
    p.sku_code,
    p.nombre AS producto,
    dp.qty_requested,
    r.reservation_id,
    r.qty_reserved,
    r.estado AS estado_reserva,
    l.lot_code,
    l.vence_en,
    b.codigo AS bodega,
    u.codigo AS ubicacion,
    m.movement_id,
    m.tipo AS tipo_movimiento,
    m.cantidad AS qty_despachada,
    m.fecha AS fecha_movimiento
FROM pedido ped
         JOIN detalle_pedido dp ON dp.order_id = ped.order_id
         JOIN producto p ON p.sku_id = dp.sku_id
         LEFT JOIN reserva r ON r.order_id = dp.order_id AND r.line_no = dp.line_no
         LEFT JOIN lote l ON l.lot_id = r.lot_id
         LEFT JOIN ubicacion u ON u.location_id = r.location_id
         LEFT JOIN bodega b ON b.warehouse_id = u.warehouse_id
         LEFT JOIN movimiento m ON m.reservation_id = r.reservation_id
ORDER BY ped.order_id, dp.line_no, r.reservation_id;


-- ----------------------------------------------------------------------------
-- CONSULTA 6: Recepciones parciales de órdenes de compra
-- Cantidad ordenada, recibida y pendiente por línea; detecta OCs completadas.
-- ----------------------------------------------------------------------------
WITH recepciones_linea AS (
    SELECT
        oc.po_id,
        pr.nombre AS proveedor,
        dc.line_no,
        p.sku_code,
        p.nombre AS producto,
        dc.qty_ordered,
        COALESCE(SUM(m.cantidad), 0) AS qty_recibida,
        dc.qty_ordered - COALESCE(SUM(m.cantidad), 0) AS qty_pendiente
    FROM orden_compra oc
             JOIN proveedor pr ON pr.supplier_id = oc.supplier_id
             JOIN detalle_compra dc ON dc.po_id = oc.po_id
             JOIN producto p ON p.sku_id = dc.sku_id
             LEFT JOIN movimiento m
                       ON m.po_id = dc.po_id
                           AND m.po_line_no = dc.line_no
                           AND m.tipo = 'RECEPCION'
    GROUP BY oc.po_id, pr.nombre, dc.line_no, p.sku_code, p.nombre, dc.qty_ordered
)
SELECT
    po_id,
    proveedor,
    line_no,
    sku_code,
    producto,
    qty_ordered,
    qty_recibida,
    qty_pendiente,
    CASE
        WHEN qty_pendiente = 0 THEN 'LINEA_COMPLETA'
        WHEN qty_recibida > 0 THEN 'LINEA_PARCIAL'
        ELSE 'SIN_RECEPCION'
        END AS estado_linea,
    CASE
        WHEN SUM(qty_pendiente) OVER (PARTITION BY po_id) = 0 THEN 'OC_COMPLETADA'
        WHEN SUM(qty_recibida) OVER (PARTITION BY po_id) > 0 THEN 'OC_PARCIAL'
        ELSE 'OC_ABIERTA'
        END AS estado_global_oc
FROM recepciones_linea
ORDER BY po_id, line_no;


-- ----------------------------------------------------------------------------
-- CONSULTA 7: Rotación y movimientos por periodo (SKU y mes)
-- Numerador: salidas del mes (DESPACHO + MERMA + AJUSTE_NEG).
-- Denominador: stock físico actual del SKU.
-- ----------------------------------------------------------------------------
WITH inventario_sku AS (
    SELECT
        l.sku_id,
        COALESCE(SUM(el.qty_on_hand), 0) AS stock_fisico_actual
    FROM lote l
             LEFT JOIN existencia_lote el ON el.lot_id = l.lot_id
    GROUP BY l.sku_id
)
SELECT
    DATE_TRUNC('month', m.fecha)::DATE AS mes,
    p.sku_code,
    p.nombre AS producto,
    COUNT(m.movement_id) AS total_movimientos,
    SUM(CASE WHEN m.tipo IN ('RECEPCION', 'AJUSTE_POS') THEN m.cantidad ELSE 0 END) AS unidades_entrada,
    SUM(CASE WHEN m.tipo IN ('DESPACHO', 'MERMA', 'AJUSTE_NEG') THEN m.cantidad ELSE 0 END) AS unidades_salida_numerador,
    COALESCE(inv.stock_fisico_actual, 0) AS stock_actual_denominador,
    ROUND(
            SUM(CASE WHEN m.tipo IN ('DESPACHO', 'MERMA', 'AJUSTE_NEG') THEN m.cantidad ELSE 0 END)::NUMERIC
                / NULLIF(COALESCE(inv.stock_fisico_actual, 0), 0),
            2
    ) AS indice_rotacion_mensual
FROM movimiento m
         JOIN lote l ON l.lot_id = m.lot_id
         JOIN producto p ON p.sku_id = l.sku_id
         LEFT JOIN inventario_sku inv ON inv.sku_id = p.sku_id
GROUP BY DATE_TRUNC('month', m.fecha), p.sku_code, p.nombre, inv.stock_fisico_actual
ORDER BY mes DESC, p.sku_code;


-- ----------------------------------------------------------------------------
-- CONSULTA 8: Quiebres y nivel de servicio (Fill Rate por línea)
-- Denominador: total de líneas de pedidos no cancelados en los últimos 30 días.
-- ----------------------------------------------------------------------------
WITH periodo AS (
    SELECT (CURRENT_DATE - INTERVAL '30 days') AS fecha_inicio, NOW() AS fecha_fin
),
     evaluacion_lineas AS (
         SELECT
             ped.order_id,
             dp.line_no,
             dp.qty_requested,
             COALESCE(SUM(r.qty_reserved) FILTER (WHERE r.estado IN ('ACTIVA', 'CONSUMIDA')), 0) AS qty_atendida,
             CASE
                 WHEN COALESCE(SUM(r.qty_reserved) FILTER (WHERE r.estado IN ('ACTIVA', 'CONSUMIDA')), 0) >= dp.qty_requested
                     THEN 'COMPLETA'
                 WHEN COALESCE(SUM(r.qty_reserved) FILTER (WHERE r.estado IN ('ACTIVA', 'CONSUMIDA')), 0) > 0
                     THEN 'PARCIAL'
                 ELSE 'NO_ATENDIDA'
                 END AS estado_atencion
         FROM pedido ped
                  JOIN detalle_pedido dp ON dp.order_id = ped.order_id
                  LEFT JOIN reserva r ON r.order_id = dp.order_id AND r.line_no = dp.line_no
                  CROSS JOIN periodo prd
         WHERE ped.estado <> 'CANCELADO'
           AND ped.creado_en BETWEEN prd.fecha_inicio AND prd.fecha_fin
         GROUP BY ped.order_id, dp.line_no, dp.qty_requested
     )
SELECT
    COUNT(*) AS total_lineas_evaluadas_denominador,
    COUNT(*) FILTER (WHERE estado_atencion = 'COMPLETA') AS lineas_completas,
    COUNT(*) FILTER (WHERE estado_atencion = 'PARCIAL') AS lineas_parciales_quiebre,
    COUNT(*) FILTER (WHERE estado_atencion = 'NO_ATENDIDA') AS lineas_no_atendidas_quiebre,
    ROUND(
            100.0 * COUNT(*) FILTER (WHERE estado_atencion = 'COMPLETA') / NULLIF(COUNT(*), 0),
            2
    ) AS nivel_servicio_pct
FROM evaluacion_lineas;
