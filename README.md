# PxWebApi2

SCB(스웨덴 통계청) PxWeb API에서 통계 데이터를 가져와 DuckDB에 저장하는 Julia 모듈입니다.

> **참조:** Stadsledningskontoret, Göteborgs Stad  
> **API:** [SCB PxWeb API](https://api.scb.se/OV0104/v1/doris/sv/ssd)  
> **데이터베이스:** `stat.duckdb`

---

## 목차

- [요구사항](#요구사항)
- [설치](#설치)
- [빠른 시작](#빠른-시작)
- [주요 함수](#주요-함수)
- [DuckDB 데이터베이스 구조](#duckdb-데이터베이스-구조)
- [출력 형식 (JSON)](#출력-형식-json)
- [사용 예시](#사용-예시)

---

## 요구사항

- Julia 1.9 이상
- 인터넷 연결 (SCB API 접근)

---

## 설치

```julia
# 프로젝트 디렉토리에서 패키지 의존성 설치
using Pkg
Pkg.activate(".")
Pkg.instantiate()
```

---

## 빠른 시작

```julia
using PxWebApi2

# 1. 클라이언트 설정
klient = PxWebKlient(
    bas_url   = "https://api.scb.se/OV0104/v1/doris/sv/ssd",
    db_sökväg = "stat.duckdb",
    timeout   = 60,
)

# 2. 특정 경로의 모든 테이블을 탐색하고 DuckDB에 저장
utforska_och_spara(klient; startväg = "BE/BE0101", max_tabeller = 5)

# 3. 저장된 데이터를 JSON으로 출력
visa_data_json("stat.duckdb", "BefolkningNy")
```

---

## 주요 함수

### `PxWebKlient` — 클라이언트 설정

```julia
klient = PxWebKlient(
    bas_url   = "https://api.scb.se/OV0104/v1/doris/sv/ssd",  # API 기본 URL
    db_sökväg = "stat.duckdb",   # DuckDB 파일 경로
    timeout   = 60,              # HTTP 타임아웃 (초)
    max_antal = 0,               # 최대 행 수 (0 = 무제한)
)
```

---

### `hämta_tabeller` — 테이블 목록 탐색

API를 재귀적으로 탐색하여 모든 테이블과 폴더 목록을 반환합니다.

```julia
# 전체 탐색
tabeller = hämta_tabeller(klient)

# 특정 경로부터 탐색
tabeller = hämta_tabeller(klient, "BE/BE0101")
```

---

### `hämta_metadata` — 테이블 메타데이터 조회

테이블의 변수명, 코드, 사용 가능한 값 목록을 조회합니다.

```julia
meta = hämta_metadata(klient, "BE/BE0101/BE0101A/BefolkningNy")

println(meta.titel)       # 테이블 제목
for v in meta.variabler
    println("$(v.kod): $(v.namn)")   # 변수 코드와 이름
    println("  값: $(v.värden[1:min(5,end)])")
end
```

---

### `hämta_data` — 데이터 가져오기

통계 데이터를 DataFrame으로 가져옵니다. `urval`로 원하는 값만 필터링할 수 있습니다.

```julia
# 모든 값 가져오기
df = hämta_data(klient, "BE/BE0101/BE0101A/BefolkningNy")

# 특정 값만 선택
df = hämta_data(klient, "BE/BE0101/BE0101A/BefolkningNy";
    urval = Dict(
        "Region"     => ["00"],                        # 스웨덴 전체
        "Kon"        => ["1", "2"],                    # 여성, 남성
        "Tid"        => ["2021", "2022", "2023"],      # 연도
    )
)
```

---

### `spara_till_duckdb` — DuckDB에 저장

DataFrame을 `stat.duckdb`에 저장합니다. 테이블명은 자동으로 `data_{tabell_id}` 형식으로 생성됩니다.

```julia
db = PxWebApi2.initiera_databas("stat.duckdb")
antal = spara_till_duckdb(db, "BefolkningNy", df, "BE/BE0101/BE0101A/BefolkningNy")
println("저장된 행 수: $antal")
```

---

### `utforska_och_spara` — 전체 파이프라인

탐색 → 메타데이터 수집 → 데이터 가져오기 → DuckDB 저장을 한 번에 실행합니다.

```julia
resultat = utforska_och_spara(klient;
    startväg     = "BE",    # 시작 경로 (빈 문자열이면 전체 탐색)
    max_tabeller = 10,      # 최대 테이블 수 (0 = 무제한)
)
```

결과는 JSON 형식으로 콘솔에 출력되며, 항상 출처 정보가 포함됩니다.

---

### `visa_tabeller` — 카탈로그 JSON 출력

DuckDB에 저장된 테이블 카탈로그를 JSON으로 출력합니다.

```julia
visa_tabeller("stat.duckdb")
```

출력 예시:
```json
{
  "källa": "Stadsledningskontoret, Göteborgs Stad",
  "tidpunkt": "2026-06-26T10:00:00",
  "databas": "stat.duckdb",
  "antal": 42,
  "tabeller": [
    { "id": "BefolkningNy", "titel": "Folkmängden...", "typ": "tabell", "sökväg": "BE/..." }
  ]
}
```

---

### `visa_data_json` — 데이터 JSON 출력

특정 테이블의 데이터를 JSON으로 출력합니다.

```julia
visa_data_json("stat.duckdb", "BefolkningNy")
```

출력 예시:
```json
{
  "källa": "Stadsledningskontoret, Göteborgs Stad",
  "tidpunkt": "2026-06-26T10:00:00",
  "tabell_id": "BefolkningNy",
  "titel": "Folkmängden efter region...",
  "antal_rader": 120,
  "kolumner": ["region", "kön", "år", "befolkning"],
  "data": [
    { "region": "Riket", "kön": "kvinnor", "år": "2023", "befolkning": "5234567" }
  ]
}
```

---

### `visa_logg` — 수집 로그 출력

모든 데이터 수집 이력을 JSON으로 출력합니다.

```julia
PxWebApi2.visa_logg("stat.duckdb")
```

---

## DuckDB 데이터베이스 구조

모든 테이블명과 컬럼명은 스웨덴어로 작성됩니다.

| 테이블 | 설명 |
|--------|------|
| `tabellkatalog` | API에서 탐색한 테이블/폴더 카탈로그 |
| `tabellvariabler` | 각 테이블의 변수 및 값 메타데이터 |
| `hämtningslogg` | 데이터 수집 이력 로그 (성공/실패 포함) |
| `data_{tabell_id}` | 실제 통계 데이터 (테이블마다 동적 생성) |

### `tabellkatalog`

| 컬럼 | 타입 | 설명 |
|------|------|------|
| `id` | TEXT | 테이블 ID (기본키) |
| `titel` | TEXT | 테이블 제목 |
| `typ` | TEXT | `tabell`(테이블) 또는 `mapp`(폴더) |
| `sökväg` | TEXT | API 경로 |
| `hämtad_vid` | TIMESTAMP | 수집 시각 |

### `hämtningslogg`

| 컬럼 | 타입 | 설명 |
|------|------|------|
| `logg_id` | INTEGER | 로그 ID (자동 증가) |
| `tabell_id` | TEXT | 테이블 ID |
| `tidpunkt` | TIMESTAMP | 수집 시각 |
| `antal_rader` | INTEGER | 저장된 행 수 |
| `status` | TEXT | `lyckad`(성공) / `misslyckad`(실패) |
| `felmeddelande` | TEXT | 오류 메시지 (실패 시) |
| `källa` | TEXT | 출처: Stadsledningskontoret, Göteborgs Stad |

---

## 출력 형식 (JSON)

모든 출력 함수는 JSON 형식으로 출력하며, **항상** 다음 필드가 포함됩니다:

```json
{
  "källa": "Stadsledningskontoret, Göteborgs Stad",
  "tidpunkt": "수집 시각",
  "databas": "stat.duckdb"
}
```

---

## 사용 예시

`exempel.jl` 파일에 전체 사용 예시가 포함되어 있습니다:

```bash
julia exempel.jl
```

또는 Julia REPL에서:

```julia
include("exempel.jl")
```

---

## 라이선스

Stadsledningskontoret, Göteborgs Stad  
데이터 출처: [SCB – Sveriges statistik](https://www.scb.se)
