"""
output.jl – Visar innehållet i stat.duckdb på ett läsbart sätt.

Källa: Stadsledningskontoret, Göteborgs Stad
"""

using Pkg
Pkg.activate(@__DIR__)

let deps = Pkg.project().dependencies
    미설치 = filter(p -> !haskey(deps, p),
                   ["DuckDB", "DataFrames", "JSON3", "Dates",
                    "Printf", "Logging"])
    if !isempty(미설치)
        Pkg.add(미설치)
    end
end

using DuckDB, DataFrames, JSON3, Dates, Printf

# ─────────────────────────────────────────────────────────────
const KÄLLA    = "Stadsledningskontoret, Göteborgs Stad"
const DB_SÖKVÄG = "stat.duckdb"
const SEP      = "─" ^ 60

# ─────────────────────────────────────────────────────────────
#  Hjälpfunktioner
# ─────────────────────────────────────────────────────────────

function rubrik(text)
    println()
    println("╔" * "═" ^ (length(text) + 2) * "╗")
    println("║ $text ║")
    println("╚" * "═" ^ (length(text) + 2) * "╝")
end

function underrubrik(text)
    println()
    println("▶ $text")
    println(SEP)
end

function tabell_rad(kolumner, bredder)
    rad = "│"
    for (k, b) in zip(kolumner, bredder)
        s = string(k === nothing ? "" : k)
        # first() hanterar Unicode-tecken korrekt (ö, å, ä etc.)
        klippt = first(s, b)
        rad *= " " * rpad(klippt, b) * " │"
    end
    println(rad)
end

function skriv_tabell(df; max_rader = 20, max_bredd = 22)
    isempty(df) && (println("  (inga rader)"); return)
    kolnamn = names(df)
    bredder = [max(length(n), max_bredd) > 30 ? 30 : max(length(n), 10) for n in kolnamn]

    # Huvud
    sep_rad = "├" * join(["─" ^ (b + 2) for b in bredder], "┼") * "┤"
    top_rad = "┌" * join(["─" ^ (b + 2) for b in bredder], "┬") * "┐"
    bot_rad = "└" * join(["─" ^ (b + 2) for b in bredder], "┴") * "┘"

    println(top_rad)
    tabell_rad(kolnamn, bredder)
    println(sep_rad)

    for (i, rad) in enumerate(eachrow(df))
        i > max_rader && (println("│ ... $(nrow(df) - max_rader) fler rader" *
            " " ^ max(0, sum(bredder) + 3*length(bredder) - 28) * "│"); break)
        tabell_rad([rad[n] for n in kolnamn], bredder)
    end
    println(bot_rad)
    println("  Totalt: $(nrow(df)) rader, $(ncol(df)) kolumner")
end

function db_fråga(db, sql, params = nothing)
    try
        result = params === nothing ?
            DuckDB.execute(db, sql) :
            DuckDB.execute(db, sql, params)
        return DataFrame(result)
    catch e
        return DataFrame()
    end
end

# ─────────────────────────────────────────────────────────────
#  Öppna databasen
# ─────────────────────────────────────────────────────────────

if !isfile(DB_SÖKVÄG)
    println("⚠  Databasen '$DB_SÖKVÄG' hittades inte.")
    println("   Kör först: julia exempel.jl")
    exit(1)
end

db = DuckDB.DB(DB_SÖKVÄG)

# ─────────────────────────────────────────────────────────────
#  1. DATABASÖVERSIKT
# ─────────────────────────────────────────────────────────────

rubrik("DATABASÖVERSIKT – $KÄLLA")

# Lista alla tabeller i DuckDB
alla_tabeller = db_fråga(db, """
    SELECT table_name, estimated_size
    FROM duckdb_tables()
    ORDER BY table_name
""")

underrubrik("Tabeller i $DB_SÖKVÄG")
for rad in eachrow(alla_tabeller)
    @printf("  %-40s  %s rader\n", rad.table_name,
            rad.estimated_size === nothing ? "?" : string(rad.estimated_size))
end

# Filstorlek
db_storlek = filesize(DB_SÖKVÄG)
println()
@printf("  Databasfil: %s  (%.1f KB)\n", DB_SÖKVÄG, db_storlek / 1024)
println("  Källa:      $KÄLLA")
println("  Tidpunkt:   $(now())")

# ─────────────────────────────────────────────────────────────
#  2. TABELLKATALOG
# ─────────────────────────────────────────────────────────────

rubrik("TABELLKATALOG")

katalog = db_fråga(db, """
    SELECT typ, COUNT(*) AS antal
    FROM tabellkatalog
    GROUP BY typ
    ORDER BY typ
""")

underrubrik("Sammanfattning")
for rad in eachrow(katalog)
    @printf("  %-10s  %d st\n", rad.typ, rad.antal)
end

underrubrik("Mappar (topp 10)")
mappar = db_fråga(db, """
    SELECT id, titel, sökväg
    FROM tabellkatalog
    WHERE typ = 'mapp'
    ORDER BY sökväg
    LIMIT 10
""")
skriv_tabell(mappar)

underrubrik("Tabeller (topp 15)")
tabeller = db_fråga(db, """
    SELECT id, titel, sökväg, hämtad_vid
    FROM tabellkatalog
    WHERE typ = 'tabell'
    ORDER BY sökväg
    LIMIT 15
""")
skriv_tabell(tabeller)

# ─────────────────────────────────────────────────────────────
#  3. SPARADE DATATABELLER
# ─────────────────────────────────────────────────────────────

rubrik("SPARADE STATISTIKTABELLER")

data_tabeller = filter(r -> startswith(r.table_name, "data_"), eachrow(alla_tabeller))

if isempty(data_tabeller)
    println("  Inga statistiktabeller sparade ännu.")
else
    for rad in data_tabeller
        tabell_id = replace(rad.table_name, "data_" => "")

        # Hämta titel
        meta = db_fråga(db,
            "SELECT titel, sökväg FROM tabellkatalog WHERE id = ?", [tabell_id])
        titel  = isempty(meta) ? tabell_id : meta[1, :titel]
        sökväg = isempty(meta) ? ""        : meta[1, :sökväg]

        underrubrik("$(rad.table_name)  →  $titel")
        println("  Sökväg: $sökväg")

        df = db_fråga(db, """SELECT * FROM "$(rad.table_name)" """)
        skriv_tabell(df)

        # JSON-utdata
        println()
        println("  JSON-utdata (5 första rader):")
        println("  " * SEP)
        json_utdata = Dict(
            "källa"       => KÄLLA,
            "tidpunkt"    => string(now()),
            "tabell_id"   => tabell_id,
            "titel"       => titel,
            "sökväg"      => sökväg,
            "antal_rader" => nrow(df),
            "kolumner"    => names(df),
            "data"        => [
                Dict(zip(names(df), Vector(r)))
                for r in eachrow(df[1:min(5, nrow(df)), :])
            ],
        )
        json_str = JSON3.write(json_utdata)
        # Visa kompakt, max 120 tecken per rad
        for rad_str in split(json_str, ",")
            println("  " * strip(rad_str))
        end
    end
end

# ─────────────────────────────────────────────────────────────
#  4. VARIABELMETADATA
# ─────────────────────────────────────────────────────────────

rubrik("VARIABELMETADATA")

variabler_summary = db_fråga(db, """
    SELECT tabell_id, COUNT(*) AS antal_variabler
    FROM tabellvariabler
    GROUP BY tabell_id
    ORDER BY tabell_id
""")

if isempty(variabler_summary)
    println("  Ingen metadata sparad ännu.")
else
    underrubrik("Antal variabler per tabell")
    skriv_tabell(variabler_summary)

    # Detalj för första tabellen
    första_tabell = variabler_summary[1, :tabell_id]
    underrubrik("Variabler för: $första_tabell")

    variabler = db_fråga(db, """
        SELECT variabelkod, variabelnamn, eliminerbar, värden
        FROM tabellvariabler
        WHERE tabell_id = ?
    """, [första_tabell])

    for v in eachrow(variabler)
        värden = try JSON3.read(v.värden) catch; [] end
        @printf("  %-20s  %-25s  %d värden\n",
                v.variabelkod, v.variabelnamn, length(värden))
        if length(värden) > 0 && length(värden) <= 10
            println("    Värden: $(join(string.(värden), ", "))")
        elseif length(värden) > 10
            println("    Värden: $(join(string.(värden[1:5]), ", ")) ... ($(length(värden)) totalt)")
        end
    end
end

# ─────────────────────────────────────────────────────────────
#  5. HÄMTNINGSLOGG
# ─────────────────────────────────────────────────────────────

rubrik("HÄMTNINGSLOGG")

logg = db_fråga(db, """
    SELECT logg_id, tabell_id, tidpunkt, antal_rader, status, felmeddelande
    FROM hämtningslogg
    ORDER BY tidpunkt DESC
""")

underrubrik("Alla hämtningar")
skriv_tabell(logg)

# Sammanfattning
lyckade    = count(r -> r.status == "lyckad",    eachrow(logg))
misslyckade = count(r -> r.status == "misslyckad", eachrow(logg))
println()
@printf("  ✓ Lyckade:      %d\n", lyckade)
@printf("  ✗ Misslyckade:  %d\n", misslyckade)

# ─────────────────────────────────────────────────────────────
#  6. FULLSTÄNDIG JSON-EXPORT (till fil)
# ─────────────────────────────────────────────────────────────

rubrik("JSON-EXPORT")

export_data = Dict(
    "källa"    => KÄLLA,
    "tidpunkt" => string(now()),
    "databas"  => DB_SÖKVÄG,
    "export"   => Dict(
        "tabellkatalog" => [
            Dict(zip(names(tabeller), Vector(r))) for r in eachrow(
                db_fråga(db, "SELECT * FROM tabellkatalog ORDER BY sökväg"))
        ],
        "hämtningslogg" => [
            Dict(zip(names(logg), Vector(r))) for r in eachrow(logg)
        ],
        "statistiktabeller" => Dict(
            rad.table_name => [
                Dict(zip(names(d), Vector(r)))
                for r in eachrow(d)
            ]
            for rad in data_tabeller
            for d in [db_fråga(db, """SELECT * FROM "$(rad.table_name)" """)]
        ),
    ),
)

json_fil = "output_$(Dates.format(now(), "yyyymmdd_HHMMSS")).json"
open(json_fil, "w") do f
    JSON3.pretty(f, export_data)
end

println("  JSON-fil sparad: $json_fil")
println("  Storlek: $(round(filesize(json_fil)/1024, digits=1)) KB")

# ─────────────────────────────────────────────────────────────
#  Avslutning
# ─────────────────────────────────────────────────────────────

close(db)

println()
println("═" ^ 60)
println("KLART – $KÄLLA")
println("Databas: $DB_SÖKVÄG  |  $(now())")
println("═" ^ 60)
