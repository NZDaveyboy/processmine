"""processmine_ml/prediction.py — LSTM next-activity prediction."""

from __future__ import annotations

from typing import Any, Optional

import numpy as np
import pandas as pd

from processmine_ml.io import validate_eventlog

__all__ = ["NextActivityPredictor"]

# ---------------------------------------------------------------------------
# Optional PyTorch import — torch lives in the [ml] extras group.
# ---------------------------------------------------------------------------

try:
    import torch  # type: ignore[import-untyped]
    import torch.nn as nn  # type: ignore[import-untyped]
    import torch.nn.functional as F  # type: ignore[import-untyped]
    from torch.utils.data import DataLoader  # type: ignore[import-untyped]
    from torch.utils.data import Dataset as _TorchDataset  # type: ignore[import-untyped]

    _TORCH_AVAILABLE = True

    class _LSTMModel(nn.Module):  # type: ignore[misc]
        def __init__(
            self,
            vocab_size: int,
            embedding_dim: int,
            hidden_size: int,
            num_layers: int,
            n_classes: int,
        ) -> None:
            super().__init__()
            self.embedding = nn.Embedding(vocab_size, embedding_dim, padding_idx=0)
            self.lstm = nn.LSTM(
                embedding_dim,
                hidden_size,
                num_layers,
                batch_first=True,
                dropout=0.1 if num_layers > 1 else 0.0,
            )
            self.fc = nn.Linear(hidden_size, n_classes)

        def forward(self, x: Any) -> Any:  # x: (batch, seq_len)
            emb = self.embedding(x)          # (batch, seq_len, embedding_dim)
            out, _ = self.lstm(emb)          # (batch, seq_len, hidden_size)
            return self.fc(out[:, -1, :])    # use last timestep → (batch, n_classes)

    class _PrefixDataset(_TorchDataset):  # type: ignore[misc]
        def __init__(
            self,
            prefixes: list[list[int]],
            targets: list[int],
            max_len: int,
        ) -> None:
            self._prefixes = prefixes
            self._targets  = targets
            self._max_len  = max_len

        def __len__(self) -> int:
            return len(self._targets)

        def __getitem__(self, idx: int) -> tuple[Any, Any]:
            seq = self._prefixes[idx]
            if len(seq) < self._max_len:
                seq = [0] * (self._max_len - len(seq)) + seq
            else:
                seq = seq[-self._max_len:]
            return (
                torch.tensor(seq,                dtype=torch.long),
                torch.tensor(self._targets[idx], dtype=torch.long),
            )

except ImportError:
    _TORCH_AVAILABLE = False


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def _require_torch() -> None:
    if not _TORCH_AVAILABLE:
        raise ImportError(
            "PyTorch is required for next-activity prediction. "
            "Install with: pip install 'processmine-ml[ml]'"
        )


class NextActivityPredictor:
    """LSTM model that predicts the next activity in a case given a prefix.

    Usage::

        predictor = NextActivityPredictor()
        predictor.fit(train_log, epochs=20)

        predictor.predict(["Create Order", "Approve Order"])
        #    activity  probability
        # 0  Pick Items     0.87
        # 1  Close Order    0.08
        # ...

        predictor.evaluate(test_log)
        # {"top1_accuracy": 0.81, "top3_accuracy": 0.95, "n_prefixes": 312}
    """

    def __init__(self) -> None:
        self._model:      Optional[Any]       = None
        self._act_to_idx: dict[str, int]      = {}
        self._idx_to_act: dict[int, str]      = {}
        self._max_seq_len: int                = 0
        self._n_acts:      int                = 0
        self._fitted:      bool               = False

    # ------------------------------------------------------------------ fit --

    def fit(
        self,
        df: pd.DataFrame,
        *,
        epochs: int           = 20,
        hidden_size: int      = 64,
        num_layers: int       = 2,
        embedding_dim: int    = 32,
        lr: float             = 0.001,
        batch_size: int       = 64,
        max_seq_len: int      = 50,
        random_state: int     = 42,
    ) -> "NextActivityPredictor":
        """Train the LSTM on an event log.

        Extracts all (prefix → next activity) pairs from *df* and trains a
        two-layer LSTM with cross-entropy loss and an Adam optimiser.

        Args:
            df: A validated processmine event log DataFrame.
            epochs: Number of training epochs. Default ``20``.
            hidden_size: LSTM hidden-state dimension. Default ``64``.
            num_layers: Number of stacked LSTM layers. Default ``2``.
            embedding_dim: Activity embedding dimension. Default ``32``.
            lr: Adam learning rate. Default ``0.001``.
            batch_size: Mini-batch size. Default ``64``.
            max_seq_len: Maximum prefix length fed to the LSTM. Longer prefixes
                are truncated to the last *max_seq_len* activities. Default ``50``.
            random_state: Seed for reproducibility. Default ``42``.

        Returns:
            ``self`` (for chaining).
        """
        _require_torch()
        validate_eventlog(df)

        torch.manual_seed(random_state)

        # Build vocabulary (1-indexed; 0 reserved for padding)
        activities = sorted(df["activity"].unique())
        self._n_acts     = len(activities)
        self._act_to_idx = {a: i + 1 for i, a in enumerate(activities)}
        self._idx_to_act = {i + 1: a  for i, a in enumerate(activities)}
        self._max_seq_len = min(max_seq_len, max(
            len(grp) for _, grp in df.groupby("case_id")
        ))

        # Build (prefix, next_activity) pairs
        prefixes: list[list[int]] = []
        targets:  list[int]       = []

        sorted_df = df.sort_values(["case_id", "timestamp"])
        for _, grp in sorted_df.groupby("case_id", sort=False):
            enc = [self._act_to_idx[a] for a in grp["activity"]]
            for i in range(1, len(enc)):
                prefixes.append(enc[:i])
                targets.append(enc[i] - 1)  # 0-based for CrossEntropyLoss

        if not targets:
            raise ValueError("No training pairs found. Each case needs at least 2 events.")

        dataset    = _PrefixDataset(prefixes, targets, self._max_seq_len)
        dataloader = DataLoader(dataset, batch_size=batch_size, shuffle=True)

        vocab_size = self._n_acts + 1  # +1 for PAD at index 0
        self._model = _LSTMModel(
            vocab_size, embedding_dim, hidden_size, num_layers, self._n_acts
        )

        optimiser = torch.optim.Adam(self._model.parameters(), lr=lr)
        criterion = nn.CrossEntropyLoss()

        self._model.train()
        for _ in range(epochs):
            for x_batch, y_batch in dataloader:
                optimiser.zero_grad()
                logits = self._model(x_batch)
                loss   = criterion(logits, y_batch)
                loss.backward()
                optimiser.step()

        self._model.eval()
        self._fitted = True
        return self

    # --------------------------------------------------------------- predict --

    def predict(
        self,
        prefix: list[str],
        top_k: int = 5,
    ) -> pd.DataFrame:
        """Predict the next activity given an activity prefix.

        Args:
            prefix: Ordered list of activity names representing the case so far.
            top_k: Number of top predictions to return. Default ``5``.

        Returns:
            DataFrame with columns ``activity`` and ``probability``, sorted by
            ``probability`` descending. Has at most ``top_k`` rows.

        Raises:
            RuntimeError: If called before :meth:`fit`.
            ValueError: If *prefix* contains an activity not seen during training.
        """
        _require_torch()
        if not self._fitted or self._model is None:
            raise RuntimeError("Call fit() before predict().")

        unknown = [a for a in prefix if a not in self._act_to_idx]
        if unknown:
            raise ValueError(
                f"Activity not seen during training: {unknown}. "
                f"Known activities: {sorted(self._act_to_idx)}"
            )

        enc = [self._act_to_idx[a] for a in prefix]
        if len(enc) < self._max_seq_len:
            enc = [0] * (self._max_seq_len - len(enc)) + enc
        else:
            enc = enc[-self._max_seq_len:]

        x = torch.tensor([enc], dtype=torch.long)
        with torch.no_grad():
            logits = self._model(x)
            probs  = F.softmax(logits, dim=-1).squeeze().numpy()

        top_k = min(top_k, self._n_acts)
        top_indices = np.argsort(probs)[::-1][:top_k]

        return pd.DataFrame({
            "activity":    [self._idx_to_act[i + 1] for i in top_indices],
            "probability": [float(probs[i])          for i in top_indices],
        })

    # -------------------------------------------------------------- evaluate --

    def evaluate(self, df: pd.DataFrame) -> dict[str, float]:
        """Compute next-activity prediction accuracy on an event log.

        Extracts all (prefix → next activity) pairs from *df* and measures
        how often the model's top-1 and top-3 predictions are correct.

        Args:
            df: A validated processmine event log DataFrame.

        Returns:
            Dict with keys ``top1_accuracy``, ``top3_accuracy``, ``n_prefixes``.
        """
        _require_torch()
        if not self._fitted or self._model is None:
            raise RuntimeError("Call fit() before evaluate().")
        validate_eventlog(df)

        sorted_df = df.sort_values(["case_id", "timestamp"])
        top1_correct = top3_correct = n = 0

        for _, grp in sorted_df.groupby("case_id", sort=False):
            acts = list(grp["activity"])
            for i in range(1, len(acts)):
                prefix_acts = acts[:i]
                true_next   = acts[i]

                # Skip activities not in training vocab
                if any(a not in self._act_to_idx for a in prefix_acts):
                    continue
                if true_next not in self._act_to_idx:
                    continue

                preds = self.predict(prefix_acts, top_k=3)
                top3  = list(preds["activity"])
                n    += 1
                if top3 and top3[0] == true_next:
                    top1_correct += 1
                if true_next in top3:
                    top3_correct += 1

        if n == 0:
            return {"top1_accuracy": 0.0, "top3_accuracy": 0.0, "n_prefixes": 0}

        return {
            "top1_accuracy": top1_correct / n,
            "top3_accuracy": top3_correct / n,
            "n_prefixes":    float(n),
        }
