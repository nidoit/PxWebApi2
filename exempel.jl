"""
Exempelskript för PxWebApi2-modulen.

Källa: Stadsledningskontoret, Göteborgs Stad
"""

using Pkg
Pkg.activate(@__DIR__)

# 필요한 패키지가 없으면 자동 설치
const 필요_패키지 = ["HTTP", "JSON3", "DuckDB", "DataFrames", "Tables"]
for pkg in 필요_패키지
    if !haskey(Pkg.project().dependencies, pkg)
        println("패키지 설치 중: $pkg")
        Pkg.add(pkg)
    end
end

using PxWebApi2

# ─────────────────────────────────────────────────────────────
#  Konfigurera klienten
# ─────────────────────────────────────────────────────────────

klient = PxWebKlient(
    bas_url   = "https://api.scb.se/OV0104/v1/doris/sv/ssd",
    db_sökväg = "stat.duckdb",
    timeout   = 60,
)

# ─────────────────────────────────────────────────────────────
#  Exempel 1: Utforska ett specifikt område och spara till DuckDB
# ─────────────────────────────────────────────────────────────
println("\n=== Exempel 1: Hämta befolkningsstatistik ===")

# Starta från befolkningsstatistik (BE)
resultat = utforska_och_spara(klient; startväg = "BE/BE0101", max_tabeller = 3)

# ─────────────────────────────────────────────────────────────
#  Exempel 2: Hämta en specifik tabell
# ─────────────────────────────────────────────────────────────
println("\n=== Exempel 2: Hämta specifik tabell ===")

sökväg = "BE/BE0101/BE0101A/BefolkningNy"

# Visa metadata
meta = hämta_metadata(klient, sökväg)
println("Tabell: $(meta.titel)")
println("Variabler:")
for v in meta.variabler
    println("  - $(v.kod): $(v.namn) ($(length(v.värden)) värden)")
end

# Hämta data med urval
df = hämta_data(klient, sökväg; urval = Dict(
    "Region" => ["00"],        # Riket
    "Civilstand" => ["OG"],    # Ogifta
    "Alder" => ["tot"],        # Totalt
    "Kon" => ["1", "2"],       # Kvinnor och män
    "Tid" => ["2020", "2021", "2022", "2023"],
))

println("\nData ($(nrow(df)) rader):")
println(df)

# Spara till DuckDB
db = PxWebApi2.initiera_databas("stat.duckdb")
antal = spara_till_duckdb(db, "BefolkningNy", df, sökväg)
println("Sparade $antal rader till stat.duckdb")

# ─────────────────────────────────────────────────────────────
#  Exempel 3: Visa sparad data som JSON
# ─────────────────────────────────────────────────────────────
println("\n=== Exempel 3: Visa data som JSON ===")
visa_data_json("stat.duckdb", "BefolkningNy")

# ─────────────────────────────────────────────────────────────
#  Exempel 4: Visa tabellkatalog
# ─────────────────────────────────────────────────────────────
println("\n=== Exempel 4: Visa tabellkatalog ===")
visa_tabeller("stat.duckdb")

# ─────────────────────────────────────────────────────────────
#  Exempel 5: Visa hämtningslogg
# ─────────────────────────────────────────────────────────────
println("\n=== Exempel 5: Visa hämtningslogg ===")
PxWebApi2.visa_logg("stat.duckdb")
