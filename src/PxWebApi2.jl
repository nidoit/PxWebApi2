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
export utforska_och_spara, visa_tabeller, visa_data_json, visa_logg

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

struct PxWebKlient
    bas_url::String
    db_sökväg::String
    timeout::Int
    max_antal::Int
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
    typ::String
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
#  DuckDB-hjälpare  (använder DB direkt, ingen separat Connection)
# ─────────────────────────────────────────────────────────────

_kör(db::DuckDB.DB, sql::String)                   = DuckDB.execute(db, sql)
_kör(db::DuckDB.DB, sql::String, params::Vector)   = DuckDB.execute(db, sql, params)
_df(db::DuckDB.DB, sql::String)                    = DataFrame(_kör(db, sql))
_df(db::DuckDB.DB, sql::String, params::Vector)    = DataFrame(_kör(db, sql, params))

# ─────────────────────────────────────────────────────────────
#  Databas-initiering
# ─────────────────────────────────────────────────────────────

"""
    initiera_databas(db_sökväg) -> DuckDB.DB

Skapar DuckDB-databasen och nödvändiga tabeller om de inte finns.
"""
function initiera_databas(db_sökväg::String)
    db = DuckDB.DB(db_sökväg)

    _kör(db, """
        CREATE TABLE IF NOT EXISTS tabellkatalog (
            id          TEXT PRIMARY KEY,
            titel       TEXT,
            typ         TEXT,
            sökväg      TEXT,
            hämtad_vid  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    """)

    _kör(db, """
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

    _kör(db, """
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

    _kör(db, "CREATE SEQUENCE IF NOT EXISTS seq_logg_id START 1")

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
    svar = HTTP.post(url, HTTP_HEADERS, JSON3.write(kropp);
                     readtimeout = timeout, retry = false)
    return JSON3.read(String(svar.body))
end

# ─────────────────────────────────────────────────────────────
#  Navigation och katalog
# ─────────────────────────────────────────────────────────────

function hämta_tabeller(klient::PxWebKlient, sökväg::String = "")
    resultat = Tabellpost[]
    _rekursiv_hämtning!(resultat, klient, sökväg)
    return resultat
end

function _rekursiv_hämtning!(lista, klient, sökväg)
    url = isempty(sökväg) ? klient.bas_url : "$(klient.bas_url)/$sökväg"
    try
        for post in _get_json(url; timeout = klient.timeout)
            id        = get(post, :id, "")
            text      = get(post, :text, "")
            typ       = get(post, :type, "")
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

function spara_tabellkatalog!(db::DuckDB.DB, tabeller::Vector{Tabellpost})
    for t in tabeller
        _kör(db, """
            INSERT OR REPLACE INTO tabellkatalog (id, titel, typ, sökväg, hämtad_vid)
            VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)
        """, [t.id, t.titel, t.typ, t.sökväg])
    end
    @info "Sparade $(length(tabeller)) poster i tabellkatalogen."
end

# ─────────────────────────────────────────────────────────────
#  Metadata
# ─────────────────────────────────────────────────────────────

function hämta_metadata(klient::PxWebKlient, sökväg::String)
    data = _get_json("$(klient.bas_url)/$sökväg"; timeout = klient.timeout)

    variabler = [
        Variabel(
            get(v, :code, ""),
            get(v, :text, ""),
            String.(get(v, :values, [])),
            String.(get(v, :valueTexts, [])),
            get(v, :elimination, false),
        )
        for v in get(data, :variables, [])
    ]

    return Tabellmetadata(get(data, :title, "Okänd"), variabler, sökväg)
end

function spara_metadata!(db::DuckDB.DB, tabell_id::String, meta::Tabellmetadata)
    for v in meta.variabler
        _kör(db, """
            INSERT OR REPLACE INTO tabellvariabler
                (tabell_id, variabelkod, variabelnamn, värden, värdetext, eliminerbar)
            VALUES (?, ?, ?, ?, ?, ?)
        """, [tabell_id, v.kod, v.namn,
              JSON3.write(v.värden), JSON3.write(v.värdetext), v.eliminerbar])
    end
end

# ─────────────────────────────────────────────────────────────
#  Datafråga
# ─────────────────────────────────────────────────────────────

function bygg_förfrågan(meta::Tabellmetadata; urval = nothing)
    fråga = map(meta.variabler) do v
        valda = (urval !== nothing && haskey(urval, v.kod)) ?
                urval[v.kod] :
                (isempty(v.värden) ? ["*"] : v.värden)
        Dict("code" => v.kod,
             "selection" => Dict("filter" => "item", "values" => valda))
    end
    return Dict("query" => fråga, "response" => Dict("format" => "json"))
end

function hämta_data(klient::PxWebKlient, sökväg::String; urval = nothing)
    meta     = hämta_metadata(klient, sökväg)
    svar     = _post_json("$(klient.bas_url)/$sökväg",
                          bygg_förfrågan(meta; urval);
                          timeout = klient.timeout)
    return _parse_svar(svar)
end

function _parse_svar(svar)
    kolnamn = [String(k[:text]) for k in svar[:columns]]
    rader   = [vcat(String.(rad[:key]), String.(rad[:values]))
               for rad in svar[:data]]

    df = DataFrame()
    for (i, namn) in enumerate(kolnamn)
        df[!, Symbol(namn)] = isempty(rader) ? String[] : [r[i] for r in rader]
    end
    return df
end

# ─────────────────────────────────────────────────────────────
#  Spara data till DuckDB
# ─────────────────────────────────────────────────────────────

function spara_till_duckdb(
    db::DuckDB.DB,
    tabell_id::String,
    df::DataFrame,
    sökväg::String,
)
    db_tabellnamn = "data_" * replace(tabell_id, r"[^a-zA-Z0-9_]" => "_")
    antal_rader   = 0
    status        = "lyckad"
    felmeddelande = nothing

    try
        DuckDB.register_data_frame(db, df, "tmp_import")
        _kör(db, """
            CREATE TABLE IF NOT EXISTS "$db_tabellnamn" AS
            SELECT * FROM tmp_import WHERE 1=0
        """)
        _kör(db, """INSERT INTO "$db_tabellnamn" SELECT * FROM tmp_import""")
        antal_rader = nrow(df)
    catch e
        status        = "misslyckad"
        felmeddelande = string(e)
        @error "Fel vid sparande av $tabell_id" undantag = e
    end

    try
        _kör(db, """
            INSERT INTO hämtningslogg
                (logg_id, tabell_id, sökväg, tidpunkt, antal_rader, status, felmeddelande)
            VALUES (nextval('seq_logg_id'), ?, ?, CURRENT_TIMESTAMP, ?, ?, ?)
        """, [tabell_id, sökväg, antal_rader, status, felmeddelande])
    catch
    end

    return antal_rader
end

# ─────────────────────────────────────────────────────────────
#  Komplett pipeline
# ─────────────────────────────────────────────────────────────

function utforska_och_spara(
    klient::PxWebKlient;
    startväg::String  = "",
    max_tabeller::Int = 0,
)
    db = initiera_databas(klient.db_sökväg)
    tidpunkt_start = now()
    @info "Startar utforskning..." bas_url = klient.bas_url

    alla_poster = hämta_tabeller(klient, startväg)
    tabeller    = filter(p -> p.typ == "tabell", alla_poster)
    mappar      = filter(p -> p.typ == "mapp",   alla_poster)
    @info "Hittade $(length(mappar)) mappar och $(length(tabeller)) tabeller."

    spara_tabellkatalog!(db, alla_poster)

    om_tabeller = max_tabeller > 0 ? tabeller[1:min(max_tabeller, length(tabeller))] : tabeller
    sparade = misslyckade = 0
    fel_lista = String[]

    for (i, tabell) in enumerate(om_tabeller)
        @info "[$i/$(length(om_tabeller))] $(tabell.sökväg)"
        try
            df   = hämta_data(klient, tabell.sökväg)
            antal = spara_till_duckdb(db, tabell.id, df, tabell.sökväg)
            spara_metadata!(db, tabell.id, hämta_metadata(klient, tabell.sökväg))
            @info "  ✓ $antal rader sparade → $(tabell.id)"
            sparade += 1
        catch e
            @warn "  ✗ Fel: $e"
            misslyckade += 1
            push!(fel_lista, "$(tabell.sökväg): $e")
        end
        sleep(0.5)
    end

    close(db)

    varaktighet = Dates.value(now() - tidpunkt_start) / 1000
    resultat = Dict(
        "källa"         => KÄLLA,
        "api_url"       => klient.bas_url,
        "databas"       => klient.db_sökväg,
        "tidpunkt"      => string(tidpunkt_start),
        "varaktighet_s" => varaktighet,
        "statistik"     => Dict(
            "antal_mappar"   => length(mappar),
            "antal_tabeller" => length(tabeller),
            "sparade"        => sparade,
            "misslyckade"    => misslyckade,
        ),
        "fel" => fel_lista,
    )

    println("\n" * "="^60)
    println("HÄMTNING SLUTFÖRD – $KÄLLA")
    println("="^60)
    println(JSON3.write(resultat))
    println("="^60)
    return resultat
end

# ─────────────────────────────────────────────────────────────
#  Visningsfunktioner (JSON-utdata)
# ─────────────────────────────────────────────────────────────

function visa_tabeller(db_sökväg::String = DB_SÖKVÄG)
    db    = DuckDB.DB(db_sökväg)
    rader = _df(db, "SELECT id, titel, typ, sökväg, hämtad_vid FROM tabellkatalog ORDER BY sökväg")
    close(db)

    utdata = Dict(
        "källa"    => KÄLLA,
        "tidpunkt" => string(now()),
        "databas"  => db_sökväg,
        "antal"    => nrow(rader),
        "tabeller" => [
            Dict("id" => r.id, "titel" => r.titel, "typ" => r.typ,
                 "sökväg" => r.sökväg, "hämtad_vid" => string(r.hämtad_vid))
            for r in eachrow(rader)
        ],
    )
    json_str = JSON3.write(utdata)
    println(json_str)
    return json_str
end

function visa_data_json(db_sökväg::String, tabell_id::String)
    db            = DuckDB.DB(db_sökväg)
    db_tabellnamn = "data_" * replace(tabell_id, r"[^a-zA-Z0-9_]" => "_")
    rader         = _df(db, """SELECT * FROM "$db_tabellnamn" LIMIT 1000""")
    meta_rad      = _df(db, "SELECT titel, sökväg FROM tabellkatalog WHERE id = ?",
                        [tabell_id])
    close(db)

    titel  = isempty(meta_rad) ? tabell_id : meta_rad[1, :titel]
    sökväg = isempty(meta_rad) ? ""        : meta_rad[1, :sökväg]

    utdata = Dict(
        "källa"      => KÄLLA,
        "tidpunkt"   => string(now()),
        "databas"    => db_sökväg,
        "tabell_id"  => tabell_id,
        "titel"      => titel,
        "sökväg"     => sökväg,
        "antal_rader"=> nrow(rader),
        "kolumner"   => names(rader),
        "data"       => [Dict(zip(names(rader), Vector(r))) for r in eachrow(rader)],
    )
    json_str = JSON3.write(utdata)
    println(json_str)
    return json_str
end

function visa_logg(db_sökväg::String = DB_SÖKVÄG)
    db    = DuckDB.DB(db_sökväg)
    rader = _df(db, """
        SELECT logg_id, tabell_id, sökväg, tidpunkt, antal_rader, status, felmeddelande, källa
        FROM hämtningslogg ORDER BY tidpunkt DESC LIMIT 100
    """)
    close(db)

    utdata = Dict(
        "källa"    => KÄLLA,
        "tidpunkt" => string(now()),
        "logg"     => [
            Dict("logg_id" => r.logg_id, "tabell_id" => r.tabell_id,
                 "sökväg" => r.sökväg, "tidpunkt" => string(r.tidpunkt),
                 "antal_rader" => r.antal_rader, "status" => r.status,
                 "felmeddelande" => r.felmeddelande, "källa" => r.källa)
            for r in eachrow(rader)
        ],
    )
    json_str = JSON3.write(utdata)
    println(json_str)
    return json_str
end

end # module PxWebApi2
