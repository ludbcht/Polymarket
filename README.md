# Polyquant — Système de recherche quantitative pour Polymarket

Système complet de simulation et de recherche quantitative pour Polymarket, conçu pour
**maximiser le rendement ajusté au risque** en n'ouvrant une position que lorsqu'un
avantage statistique mesurable est détecté — jamais au hasard, jamais à intervalle fixe.

> ⚠️ **100 % simulé.** Aucun ordre réel n'est jamais envoyé. `PolymarketClient` est
> strictement en lecture seule (aucune méthode de passage d'ordre n'existe dans le code).
> Capital de départ simulé : **100 €**.

## Sommaire

- [Architecture](#architecture)
- [Installation](#installation)
- [Démarrage rapide](#démarrage-rapide)
- [Concepts clés](#concepts-clés)
- [Stratégies](#stratégies-a-à-f)
- [Machine Learning](#machine-learning)
- [Gestion du risque](#gestion-du-risque)
- [Optimisation des paramètres](#optimisation-des-paramètres)
- [Dashboard](#dashboard)
- [Paper trading](#paper-trading)
- [Docker](#docker)
- [Tests](#tests)
- [Note sur les données réelles](#note-sur-les-données-réelles)

## Architecture

```
polymarket-quant/
├── src/polyquant/
│   ├── config.py                # Configuration centralisée (.env)
│   ├── logging_config.py        # Logging structuré (console + fichier rotatif)
│   ├── data/
│   │   ├── polymarket_client.py # Client API publique Polymarket (lecture seule)
│   │   ├── cache.py             # Cache disque avec TTL
│   │   ├── database.py          # Persistance SQLite/PostgreSQL (SQLAlchemy)
│   │   ├── models.py            # Modèles ORM + dataclasses métier
│   │   ├── replay.py            # Moteur de replay historique
│   │   └── synthetic.py         # Générateur de données synthétiques (démo/tests)
│   ├── backtest/
│   │   ├── engine.py            # Orchestrateur principal du backtest
│   │   ├── portfolio.py         # Cash, positions, PnL réalisé/latent
│   │   ├── execution.py         # Frais, slippage, impact de liquidité
│   │   └── metrics.py           # Sharpe, Sortino, drawdown, profit factor...
│   ├── strategies/               # Stratégies A à F (voir plus bas)
│   ├── ml/                       # Features, modèles (XGBoost/LightGBM/RF), pipeline
│   ├── decision/scorer.py        # Score d'opportunité composite
│   ├── risk/manager.py           # Sizing, limites d'exposition, stops dynamiques
│   ├── optimization/optuna_search.py  # Recherche d'hyperparamètres (Optuna)
│   ├── paper_trading/engine.py   # Boucle de paper trading (décision autonome)
│   └── dashboard/app.py          # Dashboard Streamlit
├── scripts/
│   ├── run_backtest.py          # CLI: lancer un backtest
│   ├── run_paper_trading.py     # CLI: lancer la boucle de paper trading
│   └── fetch_data.py            # CLI: peupler la base avec des données Polymarket réelles
├── tests/                        # Suite pytest (41 tests, ~64% de couverture)
├── Dockerfile / docker-compose.yml
└── .github/workflows/ci.yml      # Lint + tests + build Docker
```

## Installation

Prérequis : Python 3.12+

```bash
python -m venv .venv
source .venv/bin/activate          # Windows: .venv\Scripts\activate
pip install -r requirements-dev.txt
cp .env.example .env
```

Tous les paramètres (capital, seuils de risque, poids du scorer, frais simulés...) sont
configurables dans `.env` — voir `.env.example` pour la liste complète et les valeurs par
défaut.

## Démarrage rapide

### 1. Backtest avec données synthétiques (aucun réseau requis)

```bash
python scripts/run_backtest.py --n-markets 20 --n-points 500 --seed 42
```

Génère 20 marchés synthétiques réalistes (marche aléatoire bornée avec régimes de
volatilité), les rejoue cycle par cycle à travers le pipeline complet, et affiche le
rapport de performance (Sharpe, Sortino, drawdown, profit factor, etc.).

### 2. Backtest avec Machine Learning

```bash
python scripts/run_backtest.py --n-markets 20 --n-points 500 --use-ml
```

Entraîne automatiquement le meilleur modèle (XGBoost / LightGBM / Random Forest, comparés
par ROC AUC) sur l'historique disponible, puis l'utilise comme composante du score de
décision.

### 3. Dashboard interactif

```bash
streamlit run src/polyquant/dashboard/app.py
```

### 4. Paper trading (données Polymarket réelles)

```bash
python scripts/fetch_data.py          # peuple la base avec les marchés actifs réels
python scripts/run_paper_trading.py --max-cycles 12
```

## Concepts clés

Le pipeline de décision suit toujours la même chaîne, pour chaque marché à chaque cycle :

```
Historique de marché
        │
        ▼
 Stratégies A-F  ──►  Signaux (side, force, justification)
        │
        ▼
 Agrégation des signaux (rejet si conflit fort entre stratégies)
        │
        ▼
 Score d'opportunité composite (momentum, volume, liquidité, ML, spread)
        │
        ▼
 score >= seuil configurable ? ──NON──► Aucune action
        │ OUI
        ▼
 Gestionnaire de risque (sizing, exposition max, positions max, volatilité)
        │
        ▼
 Simulation d'exécution (frais, slippage, impact de liquidité)
        │
        ▼
 Portefeuille mis à jour (position ouverte, stop-loss/take-profit fixés)
```

**Aucune position n'est jamais ouverte sans signal ET score suffisant.** C'est le
garde-fou central : le système peut très bien traverser des dizaines de cycles sans
trader s'il n'y a pas d'opportunité statistiquement valable (voir la section
[Paper trading](#paper-trading)).

## Stratégies (A à F)

| # | Nom | Logique |
|---|-----|---------|
| A | Momentum probabiliste | Tendance directionnelle cohérente sur plusieurs horizons |
| B | Retour à la moyenne | Écart excessif au prix sans confirmation de volume |
| C | Anomalie de volume | Pic de volume statistiquement anormal (z-score) confirmé par un mouvement de prix |
| D | Choc de probabilité | Saut de prix brutal sur 1-2 cycles (information nouvelle) |
| E | Market making simulé | Capture de spread sur marchés calmes (faible volatilité, spread suffisant) |
| F | Classement & allocation | Score d'attractivité composite (volume/liquidité/spread/volatilité), alloue vers le top percentile |

Chaque stratégie hérite de `Strategy` (`src/polyquant/strategies/base.py`) et implémente
`generate_signal(history) -> StrategySignal | None`. Les signaux contradictoires entre
stratégies s'annulent dans le scorer plutôt que de forcer un trade.

## Machine Learning

Pipeline complet dans `src/polyquant/ml/` :

- **Features** (`features.py`) : variations de prix à 5min/15min/1h/24h, volume, z-score
  du volume, liquidité, spread, profondeur du carnet, volatilité réalisée.
- **Modèles** (`models.py`) : XGBoost, LightGBM, Random Forest, comparés automatiquement
  par accuracy / F1 / ROC AUC sur un split train/test.
- **Cible** : probabilité que le prix évolue favorablement (hausse) dans les 30 prochaines
  minutes (horizon de 6 cycles de 5 minutes).
- **Pipeline** (`pipeline.py`) : `MLPredictor.train_from_database()` construit le jeu de
  données à partir de l'historique en base, entraîne tous les modèles, sélectionne le
  meilleur par ROC AUC, et l'expose via `predict_proba(history)` au moteur de décision.

## Gestion du risque

Toutes les limites sont **contraignantes** (`src/polyquant/risk/manager.py`) :

- Risque maximal par position : **1 % du capital** (configurable)
- Exposition totale maximale : **20 % du capital**
- Maximum **5 positions simultanées**
- Stop-loss et take-profit dynamiques, fixés à l'ouverture de chaque position
- Réduction automatique de la taille de position en cas de hausse de volatilité réalisée

## Optimisation des paramètres

```python
from polyquant.optimization.optuna_search import optimize_parameters

result = optimize_parameters(cycles, initial_capital=100.0, n_trials=100)
print(result.best_params, result.best_sharpe)
```

Recherche via Optuna (TPE sampler) les paramètres — seuil de décision, risque par
position, stop-loss/take-profit, poids du scorer — qui maximisent le Sharpe ratio. Les
combinaisons n'aboutissant à aucun trade sont pénalisées pour éviter la convergence
triviale vers « ne jamais trader ».

## Dashboard

`streamlit run src/polyquant/dashboard/app.py` affiche : capital actuel, rendement,
courbe d'équité, drawdown, positions ouvertes, statistiques de sélectivité des signaux,
historique des trades clôturés et meilleurs marchés détectés par PnL.

## Paper trading

`PaperTradingEngine` (`src/polyquant/paper_trading/engine.py`) analyse le marché toutes
les 5 minutes (configurable via `PAPER_TRADING_CYCLE_MINUTES`) mais **n'ouvre une
position que si le pipeline complet (signal → score → risque) l'approuve**. À chaque
cycle, seule la meilleure opportunité détectée (le score le plus élevé) est éventuellement
tradée — le système ne multiplie pas les positions simultanées sans discernement.

## Docker

```bash
docker compose up dashboard                 # lance le dashboard sur http://localhost:8501
docker compose --profile fetch-data up       # récupère les données Polymarket réelles
docker compose --profile paper-trading up    # lance la boucle de paper trading
```

## Tests

```bash
pytest tests/ -v --cov=polyquant --cov-report=term-missing
```

41 tests unitaires et d'intégration couvrant : configuration, portefeuille, exécution
simulée, métriques de performance, stratégies, gestion du risque, scorer de décision, et
le moteur de backtest de bout en bout.

## Note sur les données réelles

`PolymarketClient` (`src/polyquant/data/polymarket_client.py`) cible les API publiques
Gamma (`https://gamma-api.polymarket.com`) et CLOB (`https://clob.polymarket.com`) de
Polymarket. Les schémas de réponse de ces API évoluent parfois ; `parse_market_state()`
est conçu pour être tolérant aux champs manquants, mais il est recommandé de vérifier la
structure des réponses actuelles avant un déploiement en production et d'ajuster le
parsing si nécessaire.

Pour développer et tester sans dépendre du réseau, `src/polyquant/data/synthetic.py`
génère des historiques de marché réalistes (marche aléatoire bornée, régimes de
volatilité, chocs occasionnels) utilisés par défaut dans les tests, le dashboard de démo
et les exemples de ce README.
