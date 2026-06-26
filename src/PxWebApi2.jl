"""
    PxWebApi2

Julia-modul för att hämta statistik från SCB:s PxWeb API och spara till DuckDB.

Källa: Stadsledningskontoret, Göteborgs Stad
API: Sveriges statistik (SCB) – https://api.scb.se
Databas: stat.duckdb
"""
module PxWebApi2

using HTTP
using JSON3
using DuckDB
using DataFrames
using Dates
using Logging
using Printf
using Tables

export PxWebKlient, hämta_tabeller, hämta_metadata, hämta_data, spara_till_duckdb
export utforska_och_spara, visa_tabeller, visa_data_json

# ─────────────────────────────────────────────────────────────
#  Konstanter och konfiguration
# ─────────────────────────────────────────────────────────────

const KÄLLA = "Stadsledningskontoret, Göteborgs Stad"
const DB_SÖKVÄG = "stat.duckdb"

const SCB_V1_URL   = "https://api.scb.se/OV0104/v1/doris/sv/ssd"
const SCB_V2_URL   = "https://api.scb.se/OV0104/v2/doris/sv/ssd"
const STANDARD_URL = SCB_V1_URL

const HTTP_HEADERS = [
    "Accept"       => "application/json",
    "Content-Type" => "application/json",
    "User-Agent"   => "PxWebApi2-Julia/0.1 ($KÄLLA)",
]

# ─────────────────────────────────────────────────────────────
#  Strukturer
# ─────────────────────────────────────────────────────────────

"""
    PxWebKlient

Konfiguration för API-klienten.
"""
struct PxWebKlient
    bas_url::String
    db_sökväg::String
    timeout::Int      # sekunder
    max_antal::Int    # max rader per tabell (0 = obegränsat)
end

PxWebKlient(;
    bas_url   = STANDARD_URL,
    db_sökväg = DB_SÖKVÄG,
    timeout   = 60,
    max_antal = 0,
) = PxWebKlient(bas_url, db_sökväg, timeout, max_antal)

struct Tabellpost
    id::String
    titel::String
    typ::String   # "l" = mapp, "t" = tabell
    sökväg::String
end

struct Variabel
    kod::String
    namn::String
    värden::Vector{String}
    värdetext::Vector{String}
    eliminerbar::Bool
end

struct Tabellmetadata
    titel::String
    variabler::Vector{Variabel}
    sökväg::String
end

# ─────────────────────────────────────────────────────────────
#  Databas-initiering
# ─────────────────────────────────────────────────────────────

"""
    initiera_databas(db_sökväg) -> DuckDB.DB

Skapar DuckDB-databasen och nödvändiga tabeller om de inte finns.
Alla tabellnamn och kolumnnamn är på svenska.
"""
function initiera_databas(db_sökväg::String)
    db = DuckDB.DB(db_sökväg)
    con = DuckDB.connect(db)

    DuckDB.execute(con, """
        CREATE TABLE IF NOT EXISTS tabellkatalog (
            id          TEXT PRIMARY KEY,
            titel       TEXT,
            typ         TEXT,
            sökväg      TEXT,
            hämtad_vid  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    """)

    DuckDB.execute(con, """
        CREATE TABLE IF NOT EXISTS tabellvariabler (
            tabell_id       TEXT,
            variabelkod     TEXT,
            variabelnamn    TEXT,
            värden          JSON,
            värdetext       JSON,
            eliminerbar     BOOLEAN,
            PRIMARY KEY (tabell_id, variabelkod)
        )
    """)

    DuckDB.execute(con, """
        CREATE TABLE IF NOT EXISTS hämtningslogg (
            logg_id         INTEGER PRIMARY KEY,
            tabell_id       TEXT,
            sökväg          TEXT,
            tidpunkt        TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            antal_rader     INTEGER,
            status          TEXT,
            felmeddelande   TEXT,
            källa           TEXT DEFAULT '$KÄLLA'
        )
    """)

    DuckDB.execute(con, """
        CREATE SEQUENCE IF NOT EXISTS seq_logg_id START 1
    """)

    DuckDB.close(con)
    return db
end

# ─────────────────────────────────────────────────────────────
#  HTTP-hjälpfunktioner
# ─────────────────────────────────────────────────────────────

function _get_json(url::String; timeout::Int = 60)
    svar = HTTP.get(url, HTTP_HEADERS; readtimeout = timeout, retry = false)
    return JSON3.read(String(svar.body))
end

function _post_json(url::String, kropp; timeout::Int = 60)
    data = JSON3.write(kropp)
    svar = HTTP.post(url, HTTP_HEADERS, data; readtimeout = timeout, retry = false)
    return JSON3.read(String(svar.body))
end

# ─────────────────────────────────────────────────────────────
#  Navigation och katalog
# ─────────────────────────────────────────────────────────────

"""
    hämta_tabeller(klient, sökväg="") -> Vector{Tabellpost}

Hämtar alla tabeller och mappar rekursivt från API:t.
`sökväg` anger startpunkt i navigationsträdet.
"""
function hämta_tabeller(klient::PxWebKlient, sökväg::String = "")
    resultat = Tabellpost[]
    _rekursiv_hämtning!(resultat, klient, sökväg)
    return resultat
end

function _rekursiv_hämtning!(
    lista::Vector{Tabellpost},
    klient::PxWebKlient,
    sökväg::String,
)
    url = isempty(sökväg) ? klient.bas_url : "$(klient.bas_url)/$sökväg"
    try
        poster = _get_json(url; timeout = klient.timeout)
        for post in poster
            id   = get(post, :id, "")
            text = get(post, :text, "")
            typ  = get(post, :type, "")
            ny_sökväg = isempty(sökväg) ? id : "$sökväg/$id"

            if typ == "t"
                push!(lista, Tabellpost(id, text, "tabell", ny_sökväg))
            elseif typ == "l"
                push!(lista, Tabellpost(id, text, "mapp", ny_sökväg))
                _rekursiv_hämtning!(lista, klient, ny_sökväg)
            end
        end
    catch e
        @warn "Kunde inte hämta sökväg: $sökväg" undantag = e
    end
end

"""
    spara_tabellkatalog!(db, tabeller)

Sparar tabellkatalogen till databasen.
"""
function spara_tabellkatalog!(db::DuckDB.DB, tabeller::Vector{Tabellpost})
    con = DuckDB.connect(db)
    try
        for t in tabeller
            DuckDB.execute(con, """
                INSERT OR REPLACE INTO tabellkatalog (id, titel, typ, sökväg, hämtad_vid)
                VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)
            """, [t.id, t.titel, t.typ, t.sökväg])
        end
    finally
        DuckDB.close(con)
    end
    @info "Sparade $(length(tabeller)) poster i tabellkatalogen."
end

# ─────────────────────────────────────────────────────────────
#  Metadata
# ─────────────────────────────────────────────────────────────

"""
    hämta_metadata(klient, sökväg) -> Tabellmetadata

Hämtar variabelbeskrivning för en specifik tabell.
"""
function hämta_metadata(klient::PxWebKlient, sökväg::String)
    url = "$(klient.bas_url)/$sökväg"
    data = _get_json(url; timeout = klient.timeout)

    titel = get(data, :title, "Okänd")
    variabler = Variabel[]

    for v in get(data, :variables, [])
        kod        = get(v, :code, "")
        namn       = get(v, :text, "")
        värden     = String.(get(v, :values, []))
        värdetext  = String.(get(v, :valueTexts, []))
        eliminerbar = get(v, :elimination, false)
        push!(variabler, Variabel(kod, namn, värden, värdetext, eliminerbar))
    end

    return Tabellmetadata(titel, variabler, sökväg)
end

"""
    spara_metadata!(db, tabell_id, metadata)

Sparar variabelmetadata till databasen.
"""
function spara_metadata!(db::DuckDB.DB, tabell_id::String, meta::Tabellmetadata)
    con = DuckDB.connect(db)
    try
        for v in meta.variabler
            DuckDB.execute(con, """
                INSERT OR REPLACE INTO tabellvariabler
                    (tabell_id, variabelkod, variabelnamn, värden, värdetext, eliminerbar)
                VALUES (?, ?, ?, ?, ?, ?)
            """, [
                tabell_id,
                v.kod,
                v.namn,
                JSON3.write(v.värden),
                JSON3.write(v.värdetext),
                v.eliminerbar,
            ])
        end
    finally
        DuckDB.close(con)
    end
end

# ─────────────────────────────────────────────────────────────
#  Datafråga
# ─────────────────────────────────────────────────────────────

"""
    bygg_förfrågan(metadata; urval=nothing) -> Dict

Bygger en PxWeb-förfrågan som väljer alla värden om inget urval anges.
`urval` är en Dict{String,Vector{String}} med variabelkod => värden.
"""
function bygg_förfrågan(meta::Tabellmetadata; urval = nothing)
    fråga = Dict{String,Any}[]

    for v in meta.variabler
        if urval !== nothing && haskey(urval, v.kod)
            valda = urval[v.kod]
        else
            valda = isempty(v.värden) ? ["*"] : v.värden
        end

        push!(fråga, Dict(
            "code"      => v.kod,
            "selection" => Dict(
                "filter" => "item",
                "values" => valda,
            ),
        ))
    end

    return Dict(
        "query"    => fråga,
        "response" => Dict("format" => "json"),
    )
end

"""
    hämta_data(klient, sökväg; urval=nothing) -> DataFrame

Hämtar statistikdata och returnerar som DataFrame.
"""
function hämta_data(klient::PxWebKlient, sökväg::String; urval = nothing)
    meta = hämta_metadata(klient, sökväg)
    förfrågan = bygg_förfrågan(meta; urval)

    url = "$(klient.bas_url)/$sökväg"
    svar = _post_json(url, förfrågan; timeout = klient.timeout)

    return _parse_svar(svar)
end

function _parse_svar(svar)
    kolumner = [String(k[:code]) for k in svar[:columns]]
    kolnamn  = [String(k[:text]) for k in svar[:columns]]
    typer    = [String(k[:type]) for k in svar[:columns]]

    rader = Vector{Any}[]
    for rad in svar[:data]
        nyckel  = String.(rad[:key])
        värden  = String.(rad[:values])
        push!(rader, vcat(nyckel, värden))
    end

    # Bygg DataFrame med svenska kolumnnamn
    n_nycklar = count(t -> t == "d", typer)
    df = DataFrame()
    for (i, namn) in enumerate(kolnamn)
        df[!, Symbol(namn)] = [r[i] for r in rader]
    end

    return df
end

# ─────────────────────────────────────────────────────────────
#  Spara data till DuckDB
# ─────────────────────────────────────────────────────────────

"""
    spara_till_duckdb(db, tabell_id, df, sökväg) -> Int

Sparar en DataFrame till en tabell i DuckDB namngiven efter tabell_id.
Returnerar antal sparade rader.
"""
function spara_till_duckdb(
    db::DuckDB.DB,
    tabell_id::String,
    df::DataFrame,
    sökväg::String,
)
    # Sanera tabellnamn för DuckDB
    db_tabellnamn = "data_" * replace(tabell_id, r"[^a-zA-Z0-9_]" => "_")

    con = DuckDB.connect(db)
    antal_rader = 0
    status = "lyckad"
    felmeddelande = nothing

    try
        # Skapa eller ersätt tabellen med data
        DuckDB.register_data_frame(con, df, "tmp_import")
        DuckDB.execute(con, """
            CREATE TABLE IF NOT EXISTS "$db_tabellnamn" AS
            SELECT * FROM tmp_import WHERE 1=0
        """)
        DuckDB.execute(con, """
            INSERT INTO "$db_tabellnamn" SELECT * FROM tmp_import
        """)
        antal_rader = nrow(df)

    catch e
        status = "misslyckad"
        felmeddelande = string(e)
        @error "Fel vid sparande av $tabell_id" undantag = e
    finally
        # Logga hämtningen
        try
            DuckDB.execute(con, """
                INSERT INTO hämtningslogg
                    (logg_id, tabell_id, sökväg, tidpunkt, antal_rader, status, felmeddelande)
                VALUES (nextval('seq_logg_id'), ?, ?, CURRENT_TIMESTAMP, ?, ?, ?)
            """, [tabell_id, sökväg, antal_rader, status, felmeddelande])
        catch
        end
        DuckDB.close(con)
    end

    return antal_rader
end

# ─────────────────────────────────────────────────────────────
#  Komplett pipeline
# ─────────────────────────────────────────────────────────────

"""
    utforska_och_spara(klient; startväg="", max_tabeller=0) -> Dict

Utforskar API:t fullständigt och sparar alla tabeller till DuckDB.
Returnerar ett JSON-kompatibelt resultat med statistik och källa.
"""
function utforska_och_spara(
    klient::PxWebKlient;
    startväg::String   = "",
    max_tabeller::Int  = 0,
)
    db = initiera_databas(klient.db_sökväg)

    tidpunkt_start = now()
    @info "Startar utforskning av PxWeb API..." bas_url = klient.bas_url

    # Hämta katalog
    alla_poster = hämta_tabeller(klient, startväg)
    tabeller    = filter(p -> p.typ == "tabell", alla_poster)
    mappar      = filter(p -> p.typ == "mapp", alla_poster)

    @info "Hittade $(length(mappar)) mappar och $(length(tabeller)) tabeller."

    # Spara katalog
    spara_tabellkatalog!(db, alla_poster)

    # Begränsa antal om önskat
    om_tabeller = max_tabeller > 0 ? tabeller[1:min(max_tabeller, end)] : tabeller

    sparade   = 0
    misslyckade = 0
    fel_lista = String[]

    for (i, tabell) in enumerate(om_tabeller)
        @info "[$i/$(length(om_tabeller))] Hämtar $(tabell.sökväg)..."
        try
            df = hämta_data(klient, tabell.sökväg)
            antal = spara_till_duckdb(db, tabell.id, df, tabell.sökväg)
            @info "  ✓ Sparade $antal rader → $(tabell.id)"
            sparade += 1

            # Spara metadata
            meta = hämta_metadata(klient, tabell.sökväg)
            spara_metadata!(db, tabell.id, meta)

        catch e
            @warn "  ✗ Fel vid $(tabell.sökväg): $e"
            misslyckade += 1
            push!(fel_lista, "$(tabell.sökväg): $e")
        end

        # Kort paus för att inte överbelasta servern
        sleep(0.5)
    end

    tidpunkt_slut = now()
    varaktighet   = Dates.value(tidpunkt_slut - tidpunkt_start) / 1000

    resultat = Dict(
        "källa"          => KÄLLA,
        "api_url"        => klient.bas_url,
        "databas"        => klient.db_sökväg,
        "tidpunkt"       => string(tidpunkt_start),
        "varaktighet_s"  => varaktighet,
        "statistik"      => Dict(
            "antal_mappar"      => length(mappar),
            "antal_tabeller"    => length(tabeller),
            "sparade"           => sparade,
            "misslyckade"       => misslyckade,
        ),
        "fel"            => fel_lista,
    )

    println("\n" * "="^60)
    println("HÄMTNING SLUTFÖRD")
    println("="^60)
    println(JSON3.write(resultat, allow_inf = false))
    println("="^60)

    return resultat
end

# ─────────────────────────────────────────────────────────────
#  Visningsfunktioner (JSON-utdata)
# ─────────────────────────────────────────────────────────────

"""
    visa_tabeller(db_sökväg) -> String

Visar alla tabeller i katalogen som JSON.
Inkluderar alltid källa: Stadsledningskontoret, Göteborgs Stad.
"""
function visa_tabeller(db_sökväg::String = DB_SÖKVÄG)
    db = DuckDB.DB(db_sökväg)
    con = DuckDB.connect(db)

    rader = DuckDB.execute(con, """
        SELECT id, titel, typ, sökväg, hämtad_vid
        FROM tabellkatalog
        ORDER BY sökväg
    """) |> DataFrame

    DuckDB.close(con)
    DuckDB.close(db)

    utdata = Dict(
        "källa"    => KÄLLA,
        "tidpunkt" => string(now()),
        "databas"  => db_sökväg,
        "tabeller" => [
            Dict(
                "id"         => row.id,
                "titel"      => row.titel,
                "typ"        => row.typ,
                "sökväg"     => row.sökväg,
                "hämtad_vid" => string(row.hämtad_vid),
            )
            for row in eachrow(rader)
        ],
        "antal" => nrow(rader),
    )

    json_str = JSON3.write(utdata)
    println(json_str)
    return json_str
end

"""
    visa_data_json(db_sökväg, tabell_id) -> String

Visar data för en specifik tabell som JSON.
Inkluderar alltid källa: Stadsledningskontoret, Göteborgs Stad.
"""
function visa_data_json(db_sökväg::String, tabell_id::String)
    db = DuckDB.DB(db_sökväg)
    con = DuckDB.connect(db)

    db_tabellnamn = "data_" * replace(tabell_id, r"[^a-zA-Z0-9_]" => "_")

    rader = DuckDB.execute(con, """
        SELECT * FROM "$db_tabellnamn" LIMIT 1000
    """) |> DataFrame

    # Hämta metadata om tabellen
    meta_rad = DuckDB.execute(con, """
        SELECT titel, sökväg FROM tabellkatalog WHERE id = ?
    """, [tabell_id]) |> DataFrame

    DuckDB.close(con)
    DuckDB.close(db)

    titel   = isempty(meta_rad) ? tabell_id : meta_rad[1, :titel]
    sökväg  = isempty(meta_rad) ? "" : meta_rad[1, :sökväg]

    utdata = Dict(
        "källa"     => KÄLLA,
        "tidpunkt"  => string(now()),
        "databas"   => db_sökväg,
        "tabell_id" => tabell_id,
        "titel"     => titel,
        "sökväg"    => sökväg,
        "antal_rader" => nrow(rader),
        "kolumner"  => names(rader),
        "data"      => [
            Dict(zip(names(rader), Vector(row)))
            for row in eachrow(rader)
        ],
    )

    json_str = JSON3.write(utdata)
    println(json_str)
    return json_str
end

"""
    visa_logg(db_sökväg) -> String

Visar hämtningsloggen som JSON.
"""
function visa_logg(db_sökväg::String = DB_SÖKVÄG)
    db = DuckDB.DB(db_sökväg)
    con = DuckDB.connect(db)

    rader = DuckDB.execute(con, """
        SELECT logg_id, tabell_id, sökväg, tidpunkt, antal_rader, status, felmeddelande, källa
        FROM hämtningslogg
        ORDER BY tidpunkt DESC
        LIMIT 100
    """) |> DataFrame

    DuckDB.close(con)
    DuckDB.close(db)

    utdata = Dict(
        "källa"    => KÄLLA,
        "tidpunkt" => string(now()),
        "logg"     => [
            Dict(
                "logg_id"       => row.logg_id,
                "tabell_id"     => row.tabell_id,
                "sökväg"        => row.sökväg,
                "tidpunkt"      => string(row.tidpunkt),
                "antal_rader"   => row.antal_rader,
                "status"        => row.status,
                "felmeddelande" => row.felmeddelande,
                "källa"         => row.källa,
            )
            for row in eachrow(rader)
        ],
    )

    json_str = JSON3.write(utdata)
    println(json_str)
    return json_str
end

end # module PxWebApi2
