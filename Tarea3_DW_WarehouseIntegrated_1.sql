/* =====================================================================================
   UNAD - Tecnologías ETL (204032) - Tarea 3: Construcción de un almacén de datos
   Caso: Comercializadora "Warehouse Integrated"
   Autor: Andrés Felipe Gallego Muñoz
   Motor: Microsoft SQL Server 2017+ (ejecutar en SSMS)

   CONTENIDO
     0. Parámetro: carpeta donde están los CSV (ajustar @Carpeta en el paso 8)
     1. Creación de la base de datos y esquemas (stg, dw, etl)
     2. Tablas de staging (todo NVARCHAR: se carga "tal cual" viene del CSV)
     3. Modelo estrella: dimensiones + tabla de hechos
     4. Tablas de control ETL: log y cuarentena de calidad
     5. Funciones auxiliares de limpieza
     6. Procedimientos almacenados ETL
          6.1 etl.sp_ExtraerCSV           -> BULK INSERT genérico a staging
          6.2 etl.sp_ETL_Clientes         -> ETL de Anexo 11 (limpieza de nulos e inconsistencias)
          6.3 etl.sp_ETL_Dimensiones      -> Tiempo, Producto, Tienda
          6.4 etl.sp_ETL_FactVentas       -> Hechos de ventas
          6.5 etl.sp_ETL_Maestro          -> Orquesta todo el proceso
     7. Cubo lógico: vista de agregación dw.vw_CuboVentas
     8. Ejecución del ETL
     9. Consultas de verificación (evidencias)

   NOTA: SQL Server lee los archivos con la cuenta de servicio del motor. Copie los CSV a
   una carpeta accesible por el servicio (p. ej. C:\ETL\Tarea3\) y quite tildes/espacios
   problemáticos de la ruta si BULK INSERT reporta "Access is denied".
===================================================================================== */

/* =====================================================================================
   1. BASE DE DATOS Y ESQUEMAS
===================================================================================== */
USE master;
GO
IF DB_ID(N'DW_WarehouseIntegrated') IS NOT NULL
BEGIN
    ALTER DATABASE DW_WarehouseIntegrated SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE DW_WarehouseIntegrated;
END
GO
CREATE DATABASE DW_WarehouseIntegrated COLLATE Modern_Spanish_CI_AS;
GO
USE DW_WarehouseIntegrated;
GO
CREATE SCHEMA stg AUTHORIZATION dbo;   -- Área de preparación (staging)
GO
CREATE SCHEMA dw  AUTHORIZATION dbo;   -- Modelo dimensional (bodega)
GO
CREATE SCHEMA etl AUTHORIZATION dbo;   -- Procesos, log y control de calidad
GO

/* =====================================================================================
   2. STAGING (copia fiel del origen, sin tipos ni reglas)
===================================================================================== */
CREATE TABLE stg.Tiendas (
    IdCiudad     NVARCHAR(50),
    Ciudad       NVARCHAR(100),
    Departamento NVARCHAR(100),
    Region       NVARCHAR(100)
);
CREATE TABLE stg.Productos (
    IdProducto     NVARCHAR(50),
    ProductoNombre NVARCHAR(200),
    Marca          NVARCHAR(100),
    Modelo         NVARCHAR(100),
    Categoria      NVARCHAR(100),
    Subcategoria   NVARCHAR(100),
    Precio         NVARCHAR(50)
);
CREATE TABLE stg.Tiempo (
    IdTiempo    NVARCHAR(50),
    Fecha       NVARCHAR(50),
    Dia         NVARCHAR(10),
    Mes         NVARCHAR(10),
    Trimestre   NVARCHAR(10),
    Anio        NVARCHAR(10),
    DiaSemana   NVARCHAR(20),
    EsFinSemana NVARCHAR(10)
);
CREATE TABLE stg.Clientes (
    IdCliente NVARCHAR(50),
    Nombre    NVARCHAR(200),
    Email     NVARCHAR(200),
    Telefono  NVARCHAR(50),
    Segmento  NVARCHAR(50),
    Ciudad    NVARCHAR(100),
    Sexo      NVARCHAR(20),
    Edad      NVARCHAR(20)
);
CREATE TABLE stg.Ventas (
    IdVenta        NVARCHAR(50),
    IdTiempo       NVARCHAR(50),
    IdCliente      NVARCHAR(50),
    IdProducto     NVARCHAR(50),
    IdTienda       NVARCHAR(50),
    Cantidad       NVARCHAR(50),
    PrecioUnitario NVARCHAR(50),
    TotalVenta     NVARCHAR(50),
    CostoUnitario  NVARCHAR(50),
    MargenUnitario NVARCHAR(50),
    MargenTotal    NVARCHAR(50)
);
GO

/* =====================================================================================
   3. MODELO ESTRELLA (dw)
===================================================================================== */
CREATE TABLE dw.DimTiempo (
    IdTiempo      INT          NOT NULL CONSTRAINT PK_DimTiempo PRIMARY KEY,
    Fecha         DATE         NOT NULL,
    Dia           TINYINT      NOT NULL,
    Mes           TINYINT      NOT NULL,
    NombreMes     NVARCHAR(15) NOT NULL,
    Trimestre     TINYINT      NOT NULL,
    Anio          SMALLINT     NOT NULL,
    AnioMes       CHAR(7)      NOT NULL,          -- 2025-01 (útil para ordenar en Power BI)
    DiaSemana     NVARCHAR(15) NOT NULL,          -- en español
    EsFinSemana   BIT          NOT NULL
);

CREATE TABLE dw.DimTienda (
    IdTienda     INT           NOT NULL CONSTRAINT PK_DimTienda PRIMARY KEY,
    Ciudad       NVARCHAR(100) NOT NULL,
    Departamento NVARCHAR(100) NOT NULL,
    Region       NVARCHAR(100) NOT NULL
);

CREATE TABLE dw.DimProducto (
    IdProducto     INT           NOT NULL CONSTRAINT PK_DimProducto PRIMARY KEY,
    ProductoNombre NVARCHAR(200) NOT NULL,
    Marca          NVARCHAR(100) NOT NULL,
    Modelo         NVARCHAR(100) NOT NULL,
    Categoria      NVARCHAR(100) NOT NULL,
    Subcategoria   NVARCHAR(100) NOT NULL,
    PrecioLista    DECIMAL(18,2) NOT NULL
);

CREATE TABLE dw.DimCliente (
    ClienteKey     INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_DimCliente PRIMARY KEY, -- llave subrogada
    IdCliente      INT           NOT NULL CONSTRAINT UQ_DimCliente_IdCliente UNIQUE, -- llave de negocio
    Nombre         NVARCHAR(150) NOT NULL,
    Email          NVARCHAR(150) NOT NULL,
    Telefono       NVARCHAR(20)  NOT NULL,
    Segmento       NVARCHAR(20)  NOT NULL,
    Ciudad         NVARCHAR(100) NOT NULL,
    Sexo           NVARCHAR(12)  NOT NULL,
    Edad           TINYINT       NULL,
    RangoEdad      NVARCHAR(15)  NOT NULL,
    FlagCalidad    NVARCHAR(200) NULL,       -- reglas que se aplicaron al registro (trazabilidad)
    FechaCarga     DATETIME2(0)  NOT NULL CONSTRAINT DF_DimCliente_FechaCarga DEFAULT SYSDATETIME()
);

CREATE TABLE dw.FactVentas (
    IdVenta        INT           NOT NULL CONSTRAINT PK_FactVentas PRIMARY KEY,
    IdTiempo       INT           NOT NULL CONSTRAINT FK_Fact_Tiempo   REFERENCES dw.DimTiempo(IdTiempo),
    ClienteKey     INT           NOT NULL CONSTRAINT FK_Fact_Cliente  REFERENCES dw.DimCliente(ClienteKey),
    IdProducto     INT           NOT NULL CONSTRAINT FK_Fact_Producto REFERENCES dw.DimProducto(IdProducto),
    IdTienda       INT           NOT NULL CONSTRAINT FK_Fact_Tienda   REFERENCES dw.DimTienda(IdTienda),
    Cantidad       INT           NOT NULL CONSTRAINT CK_Fact_Cantidad CHECK (Cantidad > 0),
    PrecioUnitario DECIMAL(18,2) NOT NULL,
    TotalVenta     DECIMAL(18,2) NOT NULL,
    CostoUnitario  DECIMAL(18,2) NOT NULL,
    MargenUnitario DECIMAL(18,2) NOT NULL,
    MargenTotal    DECIMAL(18,2) NOT NULL,
    CostoTotal     AS (CAST(Cantidad * CostoUnitario AS DECIMAL(18,2))) PERSISTED
);
CREATE INDEX IX_Fact_Tiempo   ON dw.FactVentas(IdTiempo);
CREATE INDEX IX_Fact_Producto ON dw.FactVentas(IdProducto);
CREATE INDEX IX_Fact_Tienda   ON dw.FactVentas(IdTienda);
CREATE INDEX IX_Fact_Cliente  ON dw.FactVentas(ClienteKey);
GO

/* =====================================================================================
   4. CONTROL ETL: LOG Y CUARENTENA
===================================================================================== */
CREATE TABLE etl.LogCarga (
    IdLog          INT IDENTITY(1,1) CONSTRAINT PK_LogCarga PRIMARY KEY,
    Proceso        NVARCHAR(100) NOT NULL,
    FechaInicio    DATETIME2(0)  NOT NULL,
    FechaFin       DATETIME2(0)  NULL,
    FilasLeidas    INT           NULL,
    FilasCargadas  INT           NULL,
    FilasCorregidas INT          NULL,
    FilasRechazadas INT          NULL,
    Estado         NVARCHAR(20)  NOT NULL,
    Mensaje        NVARCHAR(4000) NULL
);

-- Detalle de cada corrección o rechazo aplicado (auditoría de calidad de datos)
CREATE TABLE etl.IncidenciaCalidad (
    IdIncidencia  INT IDENTITY(1,1) CONSTRAINT PK_IncidenciaCalidad PRIMARY KEY,
    Entidad       NVARCHAR(50)  NOT NULL,
    IdRegistro    NVARCHAR(50)  NULL,
    Campo         NVARCHAR(50)  NOT NULL,
    ValorOriginal NVARCHAR(200) NULL,
    ValorFinal    NVARCHAR(200) NULL,
    Regla         NVARCHAR(100) NOT NULL,
    Accion        NVARCHAR(20)  NOT NULL,   -- CORREGIDO | IMPUTADO | RECHAZADO
    FechaRegistro DATETIME2(0)  NOT NULL CONSTRAINT DF_Incidencia_Fecha DEFAULT SYSDATETIME()
);
GO

/* =====================================================================================
   5. FUNCIONES AUXILIARES DE LIMPIEZA
===================================================================================== */
-- 5.1 Convierte vacío, espacios o el literal 'NULL' en NULL real
CREATE OR ALTER FUNCTION etl.fn_NuloSiVacio (@valor NVARCHAR(4000))
RETURNS NVARCHAR(4000)
AS
BEGIN
    DECLARE @v NVARCHAR(4000) = LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(@valor, CHAR(9), ' '), CHAR(13), ''), CHAR(10), '')));
    IF @v = N'' OR UPPER(@v) IN (N'NULL', N'N/A', N'NONE') RETURN NULL;
    RETURN @v;
END;
GO

-- 5.2 Corrige caracteres mal codificados (UTF-8 leído como OEM/ANSI, p. ej. 'G├│mez')
--     y colapsa espacios internos múltiples ('Laura  Perez' -> 'Laura Perez')
CREATE OR ALTER FUNCTION etl.fn_LimpiarTexto (@valor NVARCHAR(4000))
RETURNS NVARCHAR(4000)
AS
BEGIN
    DECLARE @v NVARCHAR(4000) = etl.fn_NuloSiVacio(@valor);
    IF @v IS NULL RETURN NULL;

    SET @v = REPLACE(@v COLLATE Latin1_General_BIN2, N'├í', N'á');
    SET @v = REPLACE(@v COLLATE Latin1_General_BIN2, N'├⌐', N'é');
    SET @v = REPLACE(@v COLLATE Latin1_General_BIN2, N'├¡', N'í');
    SET @v = REPLACE(@v COLLATE Latin1_General_BIN2, N'├│', N'ó');
    SET @v = REPLACE(@v COLLATE Latin1_General_BIN2, N'├║', N'ú');
    SET @v = REPLACE(@v COLLATE Latin1_General_BIN2, N'├▒', N'ñ');
    SET @v = REPLACE(@v COLLATE Latin1_General_BIN2, N'├ü', N'Á');
    SET @v = REPLACE(@v COLLATE Latin1_General_BIN2, N'├ë', N'É');
    SET @v = REPLACE(@v COLLATE Latin1_General_BIN2, N'├ì', N'Í');
    SET @v = REPLACE(@v COLLATE Latin1_General_BIN2, N'├ô', N'Ó');
    SET @v = REPLACE(@v COLLATE Latin1_General_BIN2, N'├Ü', N'Ú');
    SET @v = REPLACE(@v COLLATE Latin1_General_BIN2, N'├æ', N'Ñ');

    WHILE CHARINDEX(N'  ', @v) > 0
        SET @v = REPLACE(@v COLLATE Latin1_General_BIN2, N'  ', N' ');

    RETURN LTRIM(RTRIM(@v));
END;
GO

/* =====================================================================================
   6. PROCEDIMIENTOS ALMACENADOS ETL
===================================================================================== */

-- 6.1 EXTRACCIÓN: carga genérica de un CSV a una tabla de staging --------------------
CREATE OR ALTER PROCEDURE etl.sp_ExtraerCSV
    @TablaDestino NVARCHAR(128),     -- p. ej. 'stg.Clientes'
    @RutaArchivo  NVARCHAR(400)      -- p. ej. 'C:\ETL\Tarea3\Anexo 11 - Clientes - Tarea 3.csv'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @sql NVARCHAR(MAX) =
        N'TRUNCATE TABLE ' + @TablaDestino + N';
          BULK INSERT ' + @TablaDestino + N'
          FROM ''' + REPLACE(@RutaArchivo, '''', '''''') + N'''
          WITH (
              FORMAT          = ''CSV'',      -- respeta comillas: "M ", "Televisor 50"" 4K"
              FIELDQUOTE      = ''"'',
              CODEPAGE        = ''65001'',    -- UTF-8 (tildes y ñ)
              FIELDTERMINATOR = '';'',
              ROWTERMINATOR   = ''0x0d0a'',  -- CRLF (archivos generados en Windows)
              FIRSTROW        = 2,            -- omite encabezado
              TABLOCK
          );';
    EXEC sys.sp_executesql @sql;
END;
GO

-- 6.2 ETL DE CLIENTES (Anexo 11) -----------------------------------------------------
/*  POLÍTICA DE CALIDAD APLICADA
    Nulos (vacío, espacios o literal 'NULL'):
      - Nombre   -> 'NO REGISTRA'        (no se descarta: todos los clientes tienen ventas)
      - Email    -> 'NO REGISTRA'
      - Telefono -> 'NO REGISTRA'
      - Ciudad   -> ciudad de la tienda donde más compra el cliente (moda); si no hay -> 'NO REGISTRA'
      - Sexo     -> 'NO REGISTRA'
      - Edad     -> NULL (no se inventa) y RangoEdad = 'NO REGISTRA'
    Inválidos / inconsistentes:
      - Espacios al inicio/fin y dobles espacios internos -> TRIM + colapso de espacios
      - Caracteres mal codificados (├│, ├¡, ├í)          -> se corrigen a ó, í, á
      - Ciudad en distinta escritura (BOGOTA, ' CALI')     -> se homologa contra el catálogo
        oficial de ciudades (Anexo 8) comparando sin tildes ni mayúsculas -> 'Bogotá', 'Cali'
      - Sexo con espacio ('M ')                            -> 'M' / 'F'
      - Email                                              -> minúsculas; si no tiene formato válido -> 'NO REGISTRA'
      - Teléfono                                           -> solo dígitos; si no tiene 10-12 dígitos -> 'NO REGISTRA'
      - Edad fuera de 18-100 o no numérica                 -> NULL
      - IdCliente nulo, no numérico o duplicado            -> RECHAZADO (cuarentena), no entra a la bodega
*/
CREATE OR ALTER PROCEDURE etl.sp_ETL_Clientes
    @RutaArchivo NVARCHAR(400) = NULL      -- si se envía, primero extrae el CSV a staging
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @IdLog INT, @Leidas INT, @Cargadas INT, @Corregidas INT, @Rechazadas INT;
    DECLARE @NR NVARCHAR(20) = N'NO REGISTRA';

    INSERT INTO etl.LogCarga (Proceso, FechaInicio, Estado)
    VALUES (N'etl.sp_ETL_Clientes', SYSDATETIME(), N'EN PROCESO');
    SET @IdLog = SCOPE_IDENTITY();

    BEGIN TRY
        /* ---------- E: EXTRACCIÓN ---------- */
        IF @RutaArchivo IS NOT NULL
            EXEC etl.sp_ExtraerCSV @TablaDestino = N'stg.Clientes', @RutaArchivo = @RutaArchivo;

        SELECT @Leidas = COUNT(*) FROM stg.Clientes;

        /* ---------- T: TRANSFORMACIÓN ---------- */
        IF OBJECT_ID('tempdb..#Origen') IS NOT NULL DROP TABLE #Origen;
        IF OBJECT_ID('tempdb..#Limpio') IS NOT NULL DROP TABLE #Limpio;

        -- T1. Normalización base de cada campo
        SELECT
            IdClienteTxt = etl.fn_NuloSiVacio(c.IdCliente),
            IdCliente    = TRY_CAST(etl.fn_NuloSiVacio(c.IdCliente) AS INT),
            NombreOrig   = c.Nombre,
            Nombre       = etl.fn_LimpiarTexto(c.Nombre),
            EmailOrig    = c.Email,
            Email        = LOWER(etl.fn_NuloSiVacio(c.Email)),
            TelefonoOrig = c.Telefono,
            Telefono     = etl.fn_NuloSiVacio(c.Telefono),
            Segmento     = etl.fn_LimpiarTexto(c.Segmento),
            CiudadOrig   = c.Ciudad,
            Ciudad       = UPPER(etl.fn_LimpiarTexto(c.Ciudad)),
            SexoOrig     = c.Sexo,
            Sexo         = UPPER(etl.fn_NuloSiVacio(c.Sexo)),
            EdadOrig     = c.Edad,
            Edad         = TRY_CAST(etl.fn_NuloSiVacio(c.Edad) AS INT),
            NumFila      = ROW_NUMBER() OVER (PARTITION BY TRY_CAST(etl.fn_NuloSiVacio(c.IdCliente) AS INT)
                                              ORDER BY (SELECT NULL))
        INTO #Origen
        FROM stg.Clientes AS c;

        -- T2. Rechazo de registros sin llave válida o duplicados (cuarentena)
        INSERT INTO etl.IncidenciaCalidad (Entidad, IdRegistro, Campo, ValorOriginal, ValorFinal, Regla, Accion)
        SELECT N'Cliente', o.IdClienteTxt, N'IdCliente', o.IdClienteTxt, NULL,
               CASE WHEN o.IdCliente IS NULL THEN N'Llave nula o no numérica' ELSE N'Llave duplicada' END,
               N'RECHAZADO'
        FROM #Origen o
        WHERE o.IdCliente IS NULL OR o.NumFila > 1;

        SET @Rechazadas = @@ROWCOUNT;

        -- T3. Ciudad imputada = tienda donde más compra el cliente (para ciudades nulas)
        ;WITH CompraPorCiudad AS (
            SELECT v.IdCliente, t.Ciudad,
                   rn = ROW_NUMBER() OVER (PARTITION BY v.IdCliente ORDER BY COUNT(*) DESC, t.Ciudad)
            FROM (SELECT IdCliente = TRY_CAST(IdCliente AS INT), IdTienda = TRY_CAST(IdTienda AS INT) FROM stg.Ventas) v
            JOIN dw.DimTienda t ON t.IdTienda = v.IdTienda
            GROUP BY v.IdCliente, t.Ciudad
        )
        SELECT
            o.*,
            NombreFinal   = COALESCE(o.Nombre, @NR),
            EmailFinal    = CASE WHEN o.Email IS NULL THEN @NR
                                 WHEN o.Email LIKE N'%_@_%._%' AND o.Email NOT LIKE N'% %' THEN o.Email
                                 ELSE @NR END,
            TelefonoFinal = CASE WHEN o.Telefono IS NULL THEN @NR
                                 WHEN o.Telefono NOT LIKE N'%[^0-9]%' AND LEN(o.Telefono) BETWEEN 10 AND 12 THEN o.Telefono
                                 ELSE @NR END,
            SegmentoFinal = COALESCE(o.Segmento, @NR),
            -- homologación de ciudad contra el catálogo oficial (sin tildes / sin mayúsculas)
            CiudadCatalogo = (SELECT TOP (1) t.Ciudad FROM dw.DimTienda t
                              WHERE t.Ciudad COLLATE Latin1_General_CI_AI = o.Ciudad COLLATE Latin1_General_CI_AI),
            CiudadImputada = cc.Ciudad,
            SexoFinal     = CASE WHEN o.Sexo IN (N'M', N'F') THEN o.Sexo ELSE @NR END,
            EdadFinal     = CASE WHEN o.Edad BETWEEN 18 AND 100 THEN o.Edad END
        INTO #Limpio
        FROM #Origen o
        LEFT JOIN CompraPorCiudad cc ON cc.IdCliente = o.IdCliente AND cc.rn = 1
        WHERE o.IdCliente IS NOT NULL AND o.NumFila = 1;

        -- T4. Registro de auditoría de cada corrección/imputación
        INSERT INTO etl.IncidenciaCalidad (Entidad, IdRegistro, Campo, ValorOriginal, ValorFinal, Regla, Accion)
        SELECT N'Cliente', CAST(l.IdCliente AS NVARCHAR(50)), x.Campo, x.Orig, x.Final, x.Regla, x.Accion
        FROM #Limpio l
        CROSS APPLY (VALUES
            (N'Nombre',   l.NombreOrig,   l.NombreFinal,
                CASE WHEN l.Nombre IS NULL THEN N'Nulo -> NO REGISTRA' ELSE N'Trim / espacios / codificación' END,
                CASE WHEN l.Nombre IS NULL THEN N'IMPUTADO' ELSE N'CORREGIDO' END),
            (N'Email',    l.EmailOrig,    l.EmailFinal,    N'Nulo o formato inválido -> NO REGISTRA', N'IMPUTADO'),
            (N'Telefono', l.TelefonoOrig, l.TelefonoFinal, N'Nulo o formato inválido -> NO REGISTRA', N'IMPUTADO'),
            (N'Ciudad',   l.CiudadOrig,   COALESCE(l.CiudadCatalogo, l.CiudadImputada, @NR),
                CASE WHEN l.CiudadCatalogo IS NOT NULL THEN N'Homologación con catálogo de ciudades'
                     WHEN l.CiudadImputada IS NOT NULL THEN N'Nulo -> ciudad de tienda más frecuente'
                     ELSE N'Nulo -> NO REGISTRA' END,
                CASE WHEN l.CiudadCatalogo IS NOT NULL THEN N'CORREGIDO' ELSE N'IMPUTADO' END),
            (N'Sexo',     l.SexoOrig,     l.SexoFinal,
                CASE WHEN l.SexoFinal = @NR THEN N'Nulo -> NO REGISTRA' ELSE N'Trim de espacios' END,
                CASE WHEN l.SexoFinal = @NR THEN N'IMPUTADO' ELSE N'CORREGIDO' END),
            (N'Edad',     l.EdadOrig,     CAST(l.EdadFinal AS NVARCHAR(10)), N'Edad nula o fuera de rango 18-100', N'IMPUTADO')
        ) AS x (Campo, Orig, Final, Regla, Accion)
        WHERE ISNULL(x.Orig, N'<NULL>') COLLATE Latin1_General_BIN2 <> ISNULL(x.Final, N'<NULL>') COLLATE Latin1_General_BIN2;

        SELECT @Corregidas = COUNT(DISTINCT IdRegistro)
        FROM etl.IncidenciaCalidad
        WHERE Entidad = N'Cliente' AND Accion IN (N'CORREGIDO', N'IMPUTADO')
          AND FechaRegistro >= (SELECT FechaInicio FROM etl.LogCarga WHERE IdLog = @IdLog);

        /* ---------- L: CARGA (UPSERT -> SCD tipo 1) ---------- */
        BEGIN TRANSACTION;

        MERGE dw.DimCliente AS d
        USING (
            SELECT IdCliente,
                   Nombre    = LEFT(NombreFinal, 150),
                   Email     = LEFT(EmailFinal, 150),
                   Telefono  = LEFT(TelefonoFinal, 20),
                   Segmento  = LEFT(SegmentoFinal, 20),
                   Ciudad    = COALESCE(CiudadCatalogo, CiudadImputada, @NR),
                   Sexo      = SexoFinal,
                   Edad      = EdadFinal,
                   RangoEdad = CASE WHEN EdadFinal IS NULL THEN @NR
                                    WHEN EdadFinal < 30 THEN N'18-29'
                                    WHEN EdadFinal < 45 THEN N'30-44'
                                    WHEN EdadFinal < 60 THEN N'45-59'
                                    ELSE N'60+' END,
                   FlagCalidad = CASE
                        WHEN Nombre IS NULL OR Email IS NULL OR Telefono IS NULL OR Ciudad IS NULL
                             OR SexoFinal = @NR OR EdadFinal IS NULL THEN N'Campos imputados por nulos'
                        WHEN NombreOrig COLLATE Latin1_General_BIN2 <> NombreFinal COLLATE Latin1_General_BIN2
                             OR CiudadOrig COLLATE Latin1_General_BIN2 <> CiudadCatalogo COLLATE Latin1_General_BIN2
                             THEN N'Texto corregido'
                        ELSE N'OK' END
            FROM #Limpio
        ) AS s
        ON d.IdCliente = s.IdCliente
        WHEN MATCHED THEN UPDATE SET
            d.Nombre = s.Nombre, d.Email = s.Email, d.Telefono = s.Telefono, d.Segmento = s.Segmento,
            d.Ciudad = s.Ciudad, d.Sexo = s.Sexo, d.Edad = s.Edad, d.RangoEdad = s.RangoEdad,
            d.FlagCalidad = s.FlagCalidad, d.FechaCarga = SYSDATETIME()
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (IdCliente, Nombre, Email, Telefono, Segmento, Ciudad, Sexo, Edad, RangoEdad, FlagCalidad)
            VALUES (s.IdCliente, s.Nombre, s.Email, s.Telefono, s.Segmento, s.Ciudad, s.Sexo, s.Edad, s.RangoEdad, s.FlagCalidad);

        SET @Cargadas = @@ROWCOUNT;

        COMMIT TRANSACTION;

        UPDATE etl.LogCarga
           SET FechaFin = SYSDATETIME(), FilasLeidas = @Leidas, FilasCargadas = @Cargadas,
               FilasCorregidas = @Corregidas, FilasRechazadas = @Rechazadas, Estado = N'OK'
         WHERE IdLog = @IdLog;

        SELECT Proceso = N'ETL Clientes', FilasLeidas = @Leidas, FilasCargadas = @Cargadas,
               ClientesCorregidos = @Corregidas, FilasRechazadas = @Rechazadas;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        UPDATE etl.LogCarga
           SET FechaFin = SYSDATETIME(), Estado = N'ERROR', Mensaje = ERROR_MESSAGE()
         WHERE IdLog = @IdLog;
        THROW;
    END CATCH
END;
GO

-- 6.3 ETL DE DIMENSIONES TIEMPO, PRODUCTO Y TIENDA ----------------------------------
CREATE OR ALTER PROCEDURE etl.sp_ETL_Dimensiones
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Inicio DATETIME2(0) = SYSDATETIME();

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Tienda / geografía
        MERGE dw.DimTienda AS d
        USING (
            SELECT IdTienda     = TRY_CAST(IdCiudad AS INT),
                   Ciudad       = etl.fn_LimpiarTexto(Ciudad),
                   Departamento = etl.fn_LimpiarTexto(Departamento),
                   Region       = etl.fn_LimpiarTexto(Region)
            FROM stg.Tiendas
            WHERE TRY_CAST(IdCiudad AS INT) IS NOT NULL
        ) AS s ON d.IdTienda = s.IdTienda
        WHEN MATCHED THEN UPDATE SET d.Ciudad = s.Ciudad, d.Departamento = s.Departamento, d.Region = s.Region
        WHEN NOT MATCHED BY TARGET THEN INSERT VALUES (s.IdTienda, s.Ciudad, s.Departamento, s.Region);

        -- Producto
        MERGE dw.DimProducto AS d
        USING (
            SELECT IdProducto     = TRY_CAST(IdProducto AS INT),
                   ProductoNombre = etl.fn_LimpiarTexto(ProductoNombre),
                   Marca          = etl.fn_LimpiarTexto(Marca),
                   Modelo         = UPPER(etl.fn_LimpiarTexto(Modelo)),
                   Categoria      = etl.fn_LimpiarTexto(Categoria),
                   Subcategoria   = etl.fn_LimpiarTexto(Subcategoria),
                   PrecioLista    = ISNULL(TRY_CAST(Precio AS DECIMAL(18,2)), 0)
            FROM stg.Productos
            WHERE TRY_CAST(IdProducto AS INT) IS NOT NULL
        ) AS s ON d.IdProducto = s.IdProducto
        WHEN MATCHED THEN UPDATE SET d.ProductoNombre = s.ProductoNombre, d.Marca = s.Marca, d.Modelo = s.Modelo,
                                     d.Categoria = s.Categoria, d.Subcategoria = s.Subcategoria, d.PrecioLista = s.PrecioLista
        WHEN NOT MATCHED BY TARGET THEN INSERT VALUES
            (s.IdProducto, s.ProductoNombre, s.Marca, s.Modelo, s.Categoria, s.Subcategoria, s.PrecioLista);

        -- Tiempo (fecha origen en formato dd/mm/yyyy -> estilo 103)
        MERGE dw.DimTiempo AS d
        USING (
            SELECT IdTiempo  = TRY_CAST(IdTiempo AS INT),
                   Fecha     = f.Fecha,
                   Dia       = DAY(f.Fecha),
                   Mes       = MONTH(f.Fecha),
                   NombreMes = CHOOSE(MONTH(f.Fecha), N'Enero', N'Febrero', N'Marzo', N'Abril', N'Mayo', N'Junio',
                                      N'Julio', N'Agosto', N'Septiembre', N'Octubre', N'Noviembre', N'Diciembre'),
                   Trimestre = DATEPART(QUARTER, f.Fecha),
                   Anio      = YEAR(f.Fecha),
                   AnioMes   = CONVERT(CHAR(7), f.Fecha, 126),
                   DiaSemana = CASE etl.fn_NuloSiVacio(DiaSemana)
                                   WHEN 'Monday' THEN N'Lunes'     WHEN 'Tuesday'  THEN N'Martes'
                                   WHEN 'Wednesday' THEN N'Miércoles' WHEN 'Thursday' THEN N'Jueves'
                                   WHEN 'Friday' THEN N'Viernes'   WHEN 'Saturday' THEN N'Sábado'
                                   WHEN 'Sunday' THEN N'Domingo'   ELSE etl.fn_NuloSiVacio(DiaSemana) END,
                   EsFinSemana = CAST(ISNULL(TRY_CAST(EsFinSemana AS INT), 0) AS BIT)
            FROM stg.Tiempo
            CROSS APPLY (SELECT Fecha = TRY_CONVERT(DATE, etl.fn_NuloSiVacio(Fecha), 103)) f
            WHERE TRY_CAST(IdTiempo AS INT) IS NOT NULL AND f.Fecha IS NOT NULL
        ) AS s ON d.IdTiempo = s.IdTiempo
        WHEN MATCHED THEN UPDATE SET d.Fecha = s.Fecha, d.Dia = s.Dia, d.Mes = s.Mes, d.NombreMes = s.NombreMes,
                                     d.Trimestre = s.Trimestre, d.Anio = s.Anio, d.AnioMes = s.AnioMes,
                                     d.DiaSemana = s.DiaSemana, d.EsFinSemana = s.EsFinSemana
        WHEN NOT MATCHED BY TARGET THEN INSERT VALUES
            (s.IdTiempo, s.Fecha, s.Dia, s.Mes, s.NombreMes, s.Trimestre, s.Anio, s.AnioMes, s.DiaSemana, s.EsFinSemana);

        COMMIT TRANSACTION;

        INSERT INTO etl.LogCarga (Proceso, FechaInicio, FechaFin, FilasCargadas, Estado)
        VALUES (N'etl.sp_ETL_Dimensiones', @Inicio, SYSDATETIME(),
                (SELECT COUNT(*) FROM dw.DimTienda) + (SELECT COUNT(*) FROM dw.DimProducto) + (SELECT COUNT(*) FROM dw.DimTiempo),
                N'OK');
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        INSERT INTO etl.LogCarga (Proceso, FechaInicio, FechaFin, Estado, Mensaje)
        VALUES (N'etl.sp_ETL_Dimensiones', @Inicio, SYSDATETIME(), N'ERROR', ERROR_MESSAGE());
        THROW;
    END CATCH
END;
GO

-- 6.4 ETL DE HECHOS DE VENTAS -------------------------------------------------------
/*  Reglas: tipado numérico, integridad referencial contra dimensiones, cantidad > 0 y
    recálculo de TotalVenta, MargenUnitario y MargenTotal para garantizar la exactitud
    del margen de ganancia (si el valor origen no cuadra, se registra la incidencia).     */
CREATE OR ALTER PROCEDURE etl.sp_ETL_FactVentas
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Inicio DATETIME2(0) = SYSDATETIME(), @Leidas INT, @Cargadas INT, @Rechazadas INT;

    BEGIN TRY
        SELECT @Leidas = COUNT(*) FROM stg.Ventas;

        IF OBJECT_ID('tempdb..#V') IS NOT NULL DROP TABLE #V;

        SELECT IdVenta        = TRY_CAST(v.IdVenta AS INT),
               IdTiempo       = TRY_CAST(v.IdTiempo AS INT),
               IdCliente      = TRY_CAST(v.IdCliente AS INT),
               IdProducto     = TRY_CAST(v.IdProducto AS INT),
               IdTienda       = TRY_CAST(v.IdTienda AS INT),
               Cantidad       = TRY_CAST(v.Cantidad AS INT),
               PrecioUnitario = TRY_CAST(v.PrecioUnitario AS DECIMAL(18,2)),
               CostoUnitario  = TRY_CAST(v.CostoUnitario AS DECIMAL(18,2)),
               TotalVentaOrig = TRY_CAST(v.TotalVenta AS DECIMAL(18,2)),
               MargenTotalOrig= TRY_CAST(v.MargenTotal AS DECIMAL(18,2))
        INTO #V
        FROM stg.Ventas v;

        -- Rechazos: llaves que no existen en dimensiones o métricas inválidas
        INSERT INTO etl.IncidenciaCalidad (Entidad, IdRegistro, Campo, ValorOriginal, ValorFinal, Regla, Accion)
        SELECT N'Venta', CAST(v.IdVenta AS NVARCHAR(50)), N'Registro', NULL, NULL,
               N'Llave sin dimensión o métrica inválida', N'RECHAZADO'
        FROM #V v
        LEFT JOIN dw.DimTiempo   t ON t.IdTiempo   = v.IdTiempo
        LEFT JOIN dw.DimCliente  c ON c.IdCliente  = v.IdCliente
        LEFT JOIN dw.DimProducto p ON p.IdProducto = v.IdProducto
        LEFT JOIN dw.DimTienda   s ON s.IdTienda   = v.IdTienda
        WHERE v.IdVenta IS NULL OR t.IdTiempo IS NULL OR c.ClienteKey IS NULL OR p.IdProducto IS NULL
           OR s.IdTienda IS NULL OR ISNULL(v.Cantidad, 0) <= 0
           OR v.PrecioUnitario IS NULL OR v.CostoUnitario IS NULL;
        SET @Rechazadas = @@ROWCOUNT;

        -- Auditoría de totales que no cuadran con Cantidad x Precio
        INSERT INTO etl.IncidenciaCalidad (Entidad, IdRegistro, Campo, ValorOriginal, ValorFinal, Regla, Accion)
        SELECT N'Venta', CAST(IdVenta AS NVARCHAR(50)), N'TotalVenta',
               CAST(TotalVentaOrig AS NVARCHAR(50)), CAST(Cantidad * PrecioUnitario AS NVARCHAR(50)),
               N'Recalculo Cantidad x PrecioUnitario', N'CORREGIDO'
        FROM #V
        WHERE TotalVentaOrig IS NULL OR TotalVentaOrig <> Cantidad * PrecioUnitario;

        BEGIN TRANSACTION;

        MERGE dw.FactVentas AS d
        USING (
            SELECT v.IdVenta, v.IdTiempo, c.ClienteKey, v.IdProducto, v.IdTienda, v.Cantidad,
                   v.PrecioUnitario,
                   TotalVenta     = v.Cantidad * v.PrecioUnitario,
                   v.CostoUnitario,
                   MargenUnitario = v.PrecioUnitario - v.CostoUnitario,
                   MargenTotal    = v.Cantidad * (v.PrecioUnitario - v.CostoUnitario)
            FROM #V v
            JOIN dw.DimTiempo   t ON t.IdTiempo   = v.IdTiempo
            JOIN dw.DimCliente  c ON c.IdCliente  = v.IdCliente
            JOIN dw.DimProducto p ON p.IdProducto = v.IdProducto
            JOIN dw.DimTienda   s ON s.IdTienda   = v.IdTienda
            WHERE v.IdVenta IS NOT NULL AND v.Cantidad > 0
              AND v.PrecioUnitario IS NOT NULL AND v.CostoUnitario IS NOT NULL
        ) AS s ON d.IdVenta = s.IdVenta
        WHEN MATCHED THEN UPDATE SET
            d.IdTiempo = s.IdTiempo, d.ClienteKey = s.ClienteKey, d.IdProducto = s.IdProducto, d.IdTienda = s.IdTienda,
            d.Cantidad = s.Cantidad, d.PrecioUnitario = s.PrecioUnitario, d.TotalVenta = s.TotalVenta,
            d.CostoUnitario = s.CostoUnitario, d.MargenUnitario = s.MargenUnitario, d.MargenTotal = s.MargenTotal
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (IdVenta, IdTiempo, ClienteKey, IdProducto, IdTienda, Cantidad, PrecioUnitario, TotalVenta,
                    CostoUnitario, MargenUnitario, MargenTotal)
            VALUES (s.IdVenta, s.IdTiempo, s.ClienteKey, s.IdProducto, s.IdTienda, s.Cantidad, s.PrecioUnitario,
                    s.TotalVenta, s.CostoUnitario, s.MargenUnitario, s.MargenTotal);
        SET @Cargadas = @@ROWCOUNT;

        COMMIT TRANSACTION;

        INSERT INTO etl.LogCarga (Proceso, FechaInicio, FechaFin, FilasLeidas, FilasCargadas, FilasRechazadas, Estado)
        VALUES (N'etl.sp_ETL_FactVentas', @Inicio, SYSDATETIME(), @Leidas, @Cargadas, @Rechazadas, N'OK');
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        INSERT INTO etl.LogCarga (Proceso, FechaInicio, FechaFin, Estado, Mensaje)
        VALUES (N'etl.sp_ETL_FactVentas', @Inicio, SYSDATETIME(), N'ERROR', ERROR_MESSAGE());
        THROW;
    END CATCH
END;
GO

-- 6.5 ORQUESTADOR: Extrae los 5 CSV y ejecuta el ETL en orden -----------------------
CREATE OR ALTER PROCEDURE etl.sp_ETL_Maestro
    @Carpeta NVARCHAR(300)        -- p. ej. N'C:\ETL\Tarea3\'  (con barra final)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @r NVARCHAR(400);

    -- E: Extracción de los anexos a staging
    SET @r = @Carpeta + N'Anexo 8 - Tiendas - Tarea 3.csv';    EXEC etl.sp_ExtraerCSV N'stg.Tiendas',   @r;
    SET @r = @Carpeta + N'Anexo 9 - Productos - Tarea 3.csv';  EXEC etl.sp_ExtraerCSV N'stg.Productos', @r;
    SET @r = @Carpeta + N'Anexo 10- Tiempo - Tarea 3.csv';     EXEC etl.sp_ExtraerCSV N'stg.Tiempo',    @r;
    SET @r = @Carpeta + N'Anexo 11 - Clientes - Tarea 3.csv';  EXEC etl.sp_ExtraerCSV N'stg.Clientes',  @r;
    SET @r = @Carpeta + N'Anexo 12 - Ventas - Tarea 3.csv';    EXEC etl.sp_ExtraerCSV N'stg.Ventas',    @r;

    -- T + L: dimensiones primero (Clientes usa DimTienda para homologar ciudades), luego hechos
    EXEC etl.sp_ETL_Dimensiones;
    EXEC etl.sp_ETL_Clientes;
    EXEC etl.sp_ETL_FactVentas;

    SELECT * FROM etl.LogCarga ORDER BY IdLog;
END;
GO

/* =====================================================================================
   7. CUBO LÓGICO: VISTA DE AGREGACIÓN
   Granularidad: Mes, Subcategoría, Región, Departamento, Ciudad (de la tienda)
   Métricas pre-calculadas: Cantidad Vendida, Total Venta, Costo Unitario, Margen Total
   (+ Costo Total y % de margen como métricas derivadas útiles para Power BI)
===================================================================================== */
CREATE OR ALTER VIEW dw.vw_CuboVentas
AS
SELECT
    t.Anio,
    t.Mes,
    t.NombreMes,
    p.Subcategoria,
    g.Region,
    g.Departamento,
    g.Ciudad,
    NumTransacciones   = COUNT_BIG(*),
    CantidadVendida    = SUM(f.Cantidad),
    TotalVenta         = SUM(f.TotalVenta),
    CostoUnitario      = SUM(f.CostoUnitario),
    CostoTotal         = SUM(f.CostoTotal),
    MargenTotal        = SUM(f.MargenTotal),
    PorcentajeMargen   = CAST(SUM(f.MargenTotal) * 100.0 / NULLIF(SUM(f.TotalVenta), 0) AS DECIMAL(5,2))
FROM dw.FactVentas  AS f
JOIN dw.DimTiempo   AS t ON t.IdTiempo   = f.IdTiempo
JOIN dw.DimProducto AS p ON p.IdProducto = f.IdProducto
JOIN dw.DimTienda   AS g ON g.IdTienda   = f.IdTienda
GROUP BY t.Anio, t.Mes, t.NombreMes, p.Subcategoria, g.Region, g.Departamento, g.Ciudad;
GO

/* =====================================================================================
   8. EJECUCIÓN DEL ETL  (ajuste la carpeta donde copió los CSV)
===================================================================================== */
EXEC etl.sp_ETL_Maestro @Carpeta = N'C:\ETL\Tarea3\';
GO

/* =====================================================================================
   9. CONSULTAS DE VERIFICACIÓN (para capturas de pantalla)
===================================================================================== */
-- 9.1 Conteos por tabla
SELECT Tabla = 'stg.Clientes', Filas = COUNT(*) FROM stg.Clientes UNION ALL
SELECT 'dw.DimCliente',  COUNT(*) FROM dw.DimCliente  UNION ALL
SELECT 'dw.DimTiempo',   COUNT(*) FROM dw.DimTiempo   UNION ALL
SELECT 'dw.DimProducto', COUNT(*) FROM dw.DimProducto UNION ALL
SELECT 'dw.DimTienda',   COUNT(*) FROM dw.DimTienda   UNION ALL
SELECT 'dw.FactVentas',  COUNT(*) FROM dw.FactVentas;

-- 9.2 Antes vs. después: ciudades de clientes
SELECT CiudadOrigen = '[' + Ciudad + ']', Registros = COUNT(*) FROM stg.Clientes GROUP BY Ciudad ORDER BY Ciudad;
SELECT Ciudad, Registros = COUNT(*) FROM dw.DimCliente GROUP BY Ciudad ORDER BY Ciudad;

-- 9.3 Antes vs. después: nombres con espacios, nulos y mala codificación
SELECT IdCliente, NombreOrigen = '[' + Nombre + ']', Email, Telefono, Ciudad, Sexo
FROM stg.Clientes
WHERE Nombre LIKE ' %' OR Nombre LIKE '%  %' OR ISNULL(Nombre,'') = '' OR Nombre LIKE N'%├%'
   OR ISNULL(Email,'') IN ('', 'NULL') OR ISNULL(Telefono,'') IN ('', 'NULL') OR Ciudad = 'NULL' OR Sexo = 'NULL';

SELECT d.IdCliente, d.Nombre, d.Email, d.Telefono, d.Ciudad, d.Sexo, d.Edad, d.RangoEdad, d.FlagCalidad
FROM dw.DimCliente d
WHERE d.FlagCalidad <> 'OK'
ORDER BY d.IdCliente;

-- 9.4 Resumen de incidencias de calidad
SELECT Entidad, Campo, Regla, Accion, Registros = COUNT(*)
FROM etl.IncidenciaCalidad
GROUP BY Entidad, Campo, Regla, Accion
ORDER BY Entidad, Campo;

-- 9.5 Cubo lógico
SELECT TOP (50) * FROM dw.vw_CuboVentas ORDER BY Anio, Mes, Region, Departamento, Ciudad, Subcategoria;

-- 9.6 Ejemplos de análisis sobre el cubo
SELECT NombreMes, Mes, TotalVenta = SUM(TotalVenta), MargenTotal = SUM(MargenTotal)
FROM dw.vw_CuboVentas GROUP BY Mes, NombreMes ORDER BY Mes;

SELECT Region, TotalVenta = SUM(TotalVenta), MargenTotal = SUM(MargenTotal),
       PorcMargen = CAST(SUM(MargenTotal) * 100.0 / SUM(TotalVenta) AS DECIMAL(5,2))
FROM dw.vw_CuboVentas GROUP BY Region ORDER BY TotalVenta DESC;

-- 9.7 Cuadre: el total del cubo debe ser igual al total de la tabla de hechos
SELECT Fuente = 'FactVentas', TotalVenta = SUM(TotalVenta), MargenTotal = SUM(MargenTotal) FROM dw.FactVentas
UNION ALL
SELECT 'vw_CuboVentas', SUM(TotalVenta), SUM(MargenTotal) FROM dw.vw_CuboVentas;

-- 9.8 Log del proceso
SELECT * FROM etl.LogCarga ORDER BY IdLog;
GO
