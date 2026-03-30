# Logger Agent - Conversation Recording & Summary System
# 会话记录与总结专用 Agent
# 位置: ~/.openclaw/agents/logger/agent/logger_agent.py

import json
import os
import re
import sys
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional, Dict, Any, List, Set, Tuple
from urllib import error as urllib_error
from urllib import parse as urllib_parse
from urllib import request as urllib_request

# 添加 workspace 脚本路径
sys.path.insert(0, 'C:/Users/RickQ/.openclaw/workspace/scripts')
from realtime_conversation_logger import RealtimeConversationLogger

class LoggerAgent:
    """
    Logger Agent - 专门用于会话记录、总结和归档
    
    核心职责:
    1. 实时同步主 Agent 的会话到本地 Markdown
    2. 生成每日对话摘要
    3. 归档过期会话数据
    4. 提供历史记录查询
    """
    
    def __init__(self):
        self.workspace = Path("C:/Users/RickQ/.openclaw/workspace")
        self.sessions_dir = self.workspace / "sessions"
        self.memory_dir = self.workspace / "memory"
        self.archive_dir = self.workspace / "archive"
        self.reconcile_dir = self.workspace / "reconcile"
        self.main_sessions = Path("C:/Users/RickQ/.openclaw/agents/main/sessions")
        
        # 确保目录存在
        for dir_path in [self.sessions_dir, self.memory_dir, self.archive_dir, self.reconcile_dir]:
            dir_path.mkdir(parents=True, exist_ok=True)
        
        # 实时记录器
        self.rt_logger = RealtimeConversationLogger()
        
        # 状态文件
        self.state_file = self.workspace / "scripts" / ".logger_agent_state.json"
        self.state = self.load_state()
        self.sessions_index = self._load_sessions_index()
    
    def load_state(self) -> Dict:
        """加载状态文件"""
        if self.state_file.exists():
            try:
                with open(self.state_file, 'r', encoding='utf-8') as f:
                    return json.load(f)
            except:
                pass
        return {
            'last_sync_time': datetime.now().isoformat(),
            'synced_sessions': [],
            'daily_summaries': [],
            'archived_dates': []
        }
    
    def save_state(self):
        """保存状态文件"""
        self.state['last_sync_time'] = datetime.now().isoformat()
        with open(self.state_file, 'w', encoding='utf-8') as f:
            json.dump(self.state, f, indent=2, ensure_ascii=False)

    def _load_sessions_index(self) -> Dict[str, Dict[str, Any]]:
        """加载主会话索引，补充 channel/chat/session 上下文。"""
        index_file = self.main_sessions / "sessions.json"
        if not index_file.exists():
            return {}

        try:
            with open(index_file, 'r', encoding='utf-8') as f:
                raw = json.load(f)
        except Exception as exc:
            print(f"[WARN] 加载 sessions.json 失败: {exc}")
            return {}

        index: Dict[str, Dict[str, Any]] = {}
        if not isinstance(raw, dict):
            return index

        for _, value in raw.items():
            if not isinstance(value, dict):
                continue
            session_id = value.get('sessionId')
            session_file = value.get('sessionFile') or value.get('transcriptPath')
            if session_id:
                index[session_id] = value
            if session_file:
                index[Path(session_file).stem] = value

        return index
    
    # ============ 实时同步功能 ============
    
    def sync_from_main_sessions(self, date_str: Optional[str] = None) -> Dict[str, Any]:
        """
        从 main agent 的会话文件同步到本地 Markdown
        
        Args:
            date_str: 日期 (YYYY-MM-DD)，默认今天
        
        Returns:
            同步结果统计
        """
        if date_str is None:
            date_str = datetime.now().strftime("%Y-%m-%d")
        
        return self._sync_or_rebuild(date_str=date_str, overwrite=False)

    def rebuild_from_main_sessions(self, date_str: Optional[str] = None) -> Dict[str, Any]:
        """重建指定日期的 Markdown 对话文件。"""
        return self._sync_or_rebuild(date_str=date_str, overwrite=True)

    def _sync_or_rebuild(self, date_str: Optional[str], overwrite: bool) -> Dict[str, Any]:
        """同步或重建指定日期的对话文件。"""
        if date_str is None:
            date_str = datetime.now().strftime("%Y-%m-%d")

        jsonl_files = list(self.main_sessions.glob(f"*.jsonl"))
        conversation_file = self.sessions_dir / f"{date_str}-conversation.md"

        if overwrite and conversation_file.exists():
            conversation_file.unlink()
        
        total_records = 0
        synced_files = []
        
        for jsonl_file in jsonl_files:
            # 解析并同步
            session_context = self._get_session_context(jsonl_file)
            records = self._filter_records_for_date(self._parse_jsonl(jsonl_file), date_str)
            if records:
                self._sync_records_to_md(date_str, records, session_context=session_context)
                total_records += len(records)
                synced_files.append(jsonl_file.name)
        
        result = {
            'date': date_str,
            'mode': 'rebuild' if overwrite else 'sync',
            'synced_files': synced_files,
            'total_records': total_records,
            'conversation_file': str(conversation_file)
        }
        
        # 更新状态
        if date_str not in self.state['synced_sessions']:
            self.state['synced_sessions'].append(date_str)
        self.save_state()
        
        return result
    
    def _parse_jsonl(self, filepath: Path) -> List[Dict]:
        """解析 JSONL 文件"""
        records = []
        try:
            with open(filepath, 'r', encoding='utf-8') as f:
                for line in f:
                    line = line.strip()
                    if line:
                        try:
                            record = json.loads(line)
                            if record.get('type') == 'message':
                                records.append(record)
                        except json.JSONDecodeError:
                            continue
        except Exception as e:
            print(f"[ERROR] 解析文件失败 {filepath}: {e}")
        
        return records

    def _filter_records_for_date(self, records: List[Dict[str, Any]], date_str: str) -> List[Dict[str, Any]]:
        """按记录自身时间过滤目标日期，避免依赖 jsonl 文件 mtime。"""
        filtered: List[Dict[str, Any]] = []
        for record in records:
            record_dt = self._resolve_record_datetime(record)
            if record_dt and record_dt.strftime("%Y-%m-%d") == date_str:
                filtered.append(record)
        return filtered

    def _resolve_record_datetime(self, record: Dict[str, Any]) -> Optional[datetime]:
        """解析单条记录的可信时间，用于归属日期。"""
        message_data = record.get('message', {}) if isinstance(record.get('message'), dict) else {}
        candidates = [
            record.get('timestamp'),
            message_data.get('createTime'),
            message_data.get('create_time'),
            message_data.get('timestamp'),
        ]

        for candidate in candidates:
            parsed = self._parse_datetime_value(candidate)
            if parsed:
                return parsed

        return None

    def _parse_datetime_value(self, value: Any) -> Optional[datetime]:
        """兼容 ISO 字符串和 Unix 时间戳。"""
        if value in (None, ''):
            return None

        if isinstance(value, (int, float)):
            timestamp_value = value / 1000 if value > 1e12 else value
            return datetime.fromtimestamp(timestamp_value)

        if isinstance(value, str):
            stripped = value.strip()
            if not stripped:
                return None

            if stripped.isdigit():
                raw_value = int(stripped)
                timestamp_value = raw_value / 1000 if raw_value > 1e12 else raw_value
                return datetime.fromtimestamp(timestamp_value)

            try:
                return datetime.fromisoformat(stripped.replace('Z', '+00:00')).astimezone().replace(tzinfo=None)
            except ValueError:
                pass

            for pattern in ("%a %Y-%m-%d %H:%M GMT+8", "%Y-%m-%d %H:%M:%S"):
                try:
                    return datetime.strptime(stripped, pattern)
                except ValueError:
                    continue

        return None

    def _get_session_context(self, filepath: Path) -> Dict[str, Any]:
        """根据 jsonl 文件名获取会话上下文。"""
        return self.sessions_index.get(filepath.stem, {})

    def reconcile_feishu_history(self, date_str: Optional[str] = None,
                                 container_ids: Optional[List[str]] = None) -> Dict[str, Any]:
        """调用飞书历史接口，对比远端消息与本地归档的差异。"""
        if date_str is None:
            date_str = datetime.now().strftime("%Y-%m-%d")

        credentials = self._resolve_feishu_credentials()
        if not credentials:
            return {
                'date': date_str,
                'mode': 'reconcile-feishu',
                'ok': False,
                'reason': 'missing_feishu_credentials',
            }

        local_message_ids: Set[str] = set()
        chat_container_ids: Set[str] = set(container_ids or [])
        thread_container_ids: Set[str] = set()
        inspected_sessions: List[str] = []

        for jsonl_file in self.main_sessions.glob("*.jsonl"):
            session_context = self._get_session_context(jsonl_file)
            records = self._filter_records_for_date(self._parse_jsonl(jsonl_file), date_str)
            if not records:
                continue

            extracted_message_ids, chat_ids, thread_ids = self._extract_feishu_reconcile_candidates(records, session_context)
            is_feishu_session = self._is_feishu_reconcile_session(records, session_context, extracted_message_ids, chat_ids, thread_ids)
            if not is_feishu_session:
                continue

            inspected_sessions.append(jsonl_file.name)
            local_message_ids.update(extracted_message_ids)
            chat_container_ids.update(chat_ids)
            thread_container_ids.update(thread_ids)

        container_specs: List[Tuple[str, str]] = []
        container_specs.extend(('chat', container_id) for container_id in sorted(chat_container_ids) if container_id.startswith('oc_'))
        container_specs.extend(('thread', container_id) for container_id in sorted(thread_container_ids) if container_id.startswith('omt_'))

        if not container_specs:
            return {
                'date': date_str,
                'mode': 'reconcile-feishu',
                'ok': False,
                'reason': 'missing_container_id',
                'inspected_sessions': inspected_sessions,
                'local_message_count': len(local_message_ids),
                'candidate_chat_ids': sorted(chat_container_ids),
                'candidate_thread_ids': sorted(thread_container_ids),
            }

        start_dt = datetime.strptime(date_str, "%Y-%m-%d")
        end_dt = start_dt + timedelta(days=1)
        remote_items: List[Dict[str, Any]] = []
        remote_errors: List[Dict[str, Any]] = []

        for container_id_type, container_id in container_specs:
            try:
                remote_items.extend(self._list_feishu_messages(
                    app_id=credentials['app_id'],
                    app_secret=credentials['app_secret'],
                    container_id_type=container_id_type,
                    container_id=container_id,
                    start_time=int(start_dt.timestamp()),
                    end_time=int(end_dt.timestamp()),
                ))
            except Exception as exc:
                remote_errors.append({
                    'container_id_type': container_id_type,
                    'container_id': container_id,
                    'error': str(exc),
                })

        unique_remote_items: Dict[str, Dict[str, Any]] = {}
        for item in remote_items:
            message_id = item.get('message_id')
            if message_id:
                unique_remote_items[message_id] = item

        remote_only_items = [
            {
                'message_id': item.get('message_id'),
                'chat_id': item.get('chat_id'),
                'thread_id': item.get('thread_id'),
                'root_id': item.get('root_id'),
                'parent_id': item.get('parent_id'),
                'msg_type': item.get('msg_type'),
                'create_time': item.get('create_time'),
                'deleted': item.get('deleted'),
                'updated': item.get('updated'),
                'sender': item.get('sender'),
                'body': item.get('body'),
                'mentions': item.get('mentions'),
                'upper_message_id': item.get('upper_message_id'),
            }
            for item in unique_remote_items.values()
            if item.get('message_id') not in local_message_ids
        ]

        return {
            'date': date_str,
            'mode': 'reconcile-feishu',
            'ok': len(remote_errors) == 0,
            'inspected_sessions': inspected_sessions,
            'containers': [
                {
                    'container_id_type': container_id_type,
                    'container_id': container_id,
                }
                for container_id_type, container_id in container_specs
            ],
            'local_message_count': len(local_message_ids),
            'remote_message_count': len(unique_remote_items),
            'missing_local_count': len(remote_only_items),
            'missing_local_messages': remote_only_items[:50],
            'errors': remote_errors,
        }

    def reconcile_feishu_history_to_stage(self, date_str: Optional[str] = None,
                                          container_ids: Optional[List[str]] = None) -> Dict[str, Any]:
        """把飞书远端缺失消息写入 stage 文件，供人工审查。"""
        if date_str is None:
            date_str = datetime.now().strftime("%Y-%m-%d")

        result = self.reconcile_feishu_history(date_str=date_str, container_ids=container_ids)
        result['mode'] = 'reconcile-feishu-write'
        if not result.get('ok'):
            return result

        missing_items = self._resolve_full_remote_only_items(date_str=date_str, container_ids=container_ids)
        stage_records = [self._build_reconcile_stage_record(item) for item in missing_items]
        stage_file = self._get_reconcile_stage_file(date_str)
        payload = {
            'date': date_str,
            'generated_at': datetime.now().isoformat(),
            'containers': result.get('containers', []),
            'missing_local_count': len(stage_records),
            'records': stage_records,
        }
        stage_file.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding='utf-8')

        return {
            **result,
            'stage_file': str(stage_file),
            'staged_count': len(stage_records),
        }

    def merge_reconcile_stage(self, date_str: Optional[str] = None) -> Dict[str, Any]:
        """将 stage 文件中的补账消息合并进当天对话 Markdown。"""
        if date_str is None:
            date_str = datetime.now().strftime("%Y-%m-%d")

        stage_file = self._get_reconcile_stage_file(date_str)
        if not stage_file.exists():
            return {
                'date': date_str,
                'mode': 'reconcile-feishu-merge',
                'ok': False,
                'reason': 'missing_stage_file',
                'stage_file': str(stage_file),
            }

        payload = json.loads(stage_file.read_text(encoding='utf-8'))
        records = payload.get('records', []) if isinstance(payload.get('records'), list) else []
        conversation_file = self.sessions_dir / f"{date_str}-conversation.md"
        if not conversation_file.exists():
            date_display = datetime.strptime(date_str, "%Y-%m-%d").strftime("%Y年%m月%d日")
            header = f"""# 对话记录
**日期**: {date_display}
**记录模式**: ✅ Logger Agent 同步
**同步时间**: {datetime.now().strftime("%Y-%m-%d %H:%M:%S")}

---

"""
            conversation_file.write_text(header, encoding='utf-8')

        existing_message_ids = self._collect_existing_markdown_message_ids(conversation_file)
        merged_count = 0

        with open(conversation_file, 'a', encoding='utf-8') as handle:
            for record in records:
                metadata = record.get('metadata', {}) if isinstance(record.get('metadata'), dict) else {}
                message_id = metadata.get('message_id')
                if message_id in existing_message_ids:
                    continue

                role_name = record.get('role_name') or 'Feishu'
                time_str = record.get('time') or '00:00'
                content = record.get('content') or '[无内容]'
                metadata_block = self.rt_logger.format_metadata_block(metadata, fallback_timestamp=time_str)
                handle.write(f"**{role_name}** {time_str} [补账]\n{metadata_block}{content}\n\n---\n\n")
                if message_id:
                    existing_message_ids.add(message_id)
                merged_count += 1

        return {
            'date': date_str,
            'mode': 'reconcile-feishu-merge',
            'ok': True,
            'stage_file': str(stage_file),
            'conversation_file': str(conversation_file),
            'merged_count': merged_count,
            'skipped_existing_count': len(records) - merged_count,
        }

    def _resolve_full_remote_only_items(self, date_str: str,
                                        container_ids: Optional[List[str]] = None) -> List[Dict[str, Any]]:
        """获取完整的远端缺失消息集合，用于 stage 写入。"""
        credentials = self._resolve_feishu_credentials()
        if not credentials:
            return []

        local_message_ids: Set[str] = set()
        chat_container_ids: Set[str] = set(container_ids or [])
        thread_container_ids: Set[str] = set()

        for jsonl_file in self.main_sessions.glob("*.jsonl"):
            session_context = self._get_session_context(jsonl_file)
            records = self._filter_records_for_date(self._parse_jsonl(jsonl_file), date_str)
            if not records:
                continue
            extracted_message_ids, chat_ids, thread_ids = self._extract_feishu_reconcile_candidates(records, session_context)
            if not self._is_feishu_reconcile_session(records, session_context, extracted_message_ids, chat_ids, thread_ids):
                continue
            local_message_ids.update(extracted_message_ids)
            chat_container_ids.update(chat_ids)
            thread_container_ids.update(thread_ids)

        container_specs: List[Tuple[str, str]] = []
        container_specs.extend(('chat', container_id) for container_id in sorted(chat_container_ids) if container_id.startswith('oc_'))
        container_specs.extend(('thread', container_id) for container_id in sorted(thread_container_ids) if container_id.startswith('omt_'))

        start_dt = datetime.strptime(date_str, "%Y-%m-%d")
        end_dt = start_dt + timedelta(days=1)
        unique_remote_items: Dict[str, Dict[str, Any]] = {}

        for container_id_type, container_id in container_specs:
            for item in self._list_feishu_messages(
                app_id=credentials['app_id'],
                app_secret=credentials['app_secret'],
                container_id_type=container_id_type,
                container_id=container_id,
                start_time=int(start_dt.timestamp()),
                end_time=int(end_dt.timestamp()),
            ):
                message_id = item.get('message_id')
                if message_id:
                    unique_remote_items[message_id] = item

        return [
            item for item in unique_remote_items.values()
            if item.get('message_id') not in local_message_ids
        ]

    def _build_reconcile_stage_record(self, item: Dict[str, Any]) -> Dict[str, Any]:
        """把飞书 history item 转成可合并的 stage record。"""
        body_payload = item.get('body') if isinstance(item.get('body'), dict) else {}
        raw_body_content = body_payload.get('content') if isinstance(body_payload.get('content'), str) else None
        sender = item.get('sender') if isinstance(item.get('sender'), dict) else {}
        sender_type = sender.get('sender_type')
        role_name = 'CC' if sender_type == 'app' else 'Rick'
        direction = 'outbound' if sender_type == 'app' else 'inbound'
        content = self._render_feishu_history_content(item)
        create_dt = self._parse_datetime_value(item.get('create_time'))
        time_str = create_dt.strftime('%H:%M') if create_dt else '00:00'
        metadata = self.rt_logger.normalize_metadata({
            'channel': 'feishu',
            'direction': direction,
            'metadata_sources': ['feishu_history_reconcile'],
            'message_id': item.get('message_id'),
            'reply_to_id': item.get('parent_id'),
            'root_id': item.get('root_id'),
            'parent_id': item.get('parent_id'),
            'thread_id': item.get('thread_id'),
            'upper_message_id': item.get('upper_message_id'),
            'chat_id': item.get('chat_id'),
            'msg_type': item.get('msg_type'),
            'sender': sender.get('id') or sender.get('sender_type'),
            'sender_id': sender.get('id'),
            'sender_id_type': sender.get('id_type'),
            'sender_type': sender.get('sender_type'),
            'sender_tenant_key': sender.get('tenant_key'),
            'create_time': item.get('create_time'),
            'update_time': item.get('update_time'),
            'deleted': item.get('deleted'),
            'updated': item.get('updated'),
            'mentions': item.get('mentions'),
            'raw_body_content': raw_body_content,
            'raw_body_length': len(raw_body_content) if raw_body_content else None,
            'to': item.get('chat_id'),
        })
        return {
            'role_name': role_name,
            'time': time_str,
            'content': content,
            'metadata': metadata,
        }

    def _render_feishu_history_content(self, item: Dict[str, Any]) -> str:
        """把飞书 history 消息渲染成可读正文。"""
        body_payload = item.get('body') if isinstance(item.get('body'), dict) else {}
        raw_body_content = body_payload.get('content') if isinstance(body_payload.get('content'), str) else ''
        msg_type = item.get('msg_type') or 'unknown'
        if not raw_body_content:
            return f"[飞书历史补账消息: {msg_type}]"

        if msg_type == 'text':
            try:
                parsed = json.loads(raw_body_content)
            except json.JSONDecodeError:
                return raw_body_content
            if isinstance(parsed, dict) and isinstance(parsed.get('text'), str) and parsed.get('text').strip():
                return parsed.get('text').strip()
            return raw_body_content

        if msg_type == 'post':
            return f"[飞书历史补账消息: post]\n```json\n{raw_body_content}\n```"

        return f"[飞书历史补账消息: {msg_type}]\n```json\n{raw_body_content}\n```"

    def _get_reconcile_stage_file(self, date_str: str) -> Path:
        """获取飞书补账 stage 文件路径。"""
        return self.reconcile_dir / f"{date_str}-feishu-reconcile-stage.json"

    def _collect_existing_markdown_message_ids(self, conversation_file: Path) -> Set[str]:
        """收集 Markdown 归档里已有的 message_id，避免 merge 重复。"""
        if not conversation_file.exists():
            return set()
        content = conversation_file.read_text(encoding='utf-8')
        return set(re.findall(r'"message_id"\s*:\s*"(om_[A-Za-z0-9]+)"', content))

    def _extract_feishu_reconcile_candidates(self, records: List[Dict[str, Any]],
                                             session_context: Dict[str, Any]) -> Tuple[Set[str], Set[str], Set[str]]:
        """从本地会话记录中提取飞书 reconciliation 需要的 message/container 标识。"""
        message_ids: Set[str] = set()
        chat_ids: Set[str] = set()
        thread_ids: Set[str] = set()

        session_chat_id = session_context.get('chatId') or session_context.get('deliveryContext', {}).get('chatId')
        session_thread_id = session_context.get('threadId') or session_context.get('deliveryContext', {}).get('threadId')
        if isinstance(session_chat_id, str):
            chat_ids.update(re.findall(r'\boc_[A-Za-z0-9]+\b', session_chat_id))
        if isinstance(session_thread_id, str):
            thread_ids.update(re.findall(r'\bomt_[A-Za-z0-9]+\b', session_thread_id))

        for record in records:
            message_data = record.get('message', {}) if isinstance(record.get('message'), dict) else {}
            _, metadata = self._extract_content_and_metadata(record, message_data, session_context)

            for key in ('message_id', 'reply_to_id', 'root_id', 'parent_id', 'upper_message_id'):
                value = metadata.get(key)
                if isinstance(value, str) and value.startswith('om_'):
                    message_ids.add(value)

            for key in ('chat_id',):
                value = metadata.get(key)
                if isinstance(value, str):
                    chat_ids.update(re.findall(r'\boc_[A-Za-z0-9]+\b', value))

            for key in ('thread_id',):
                value = metadata.get(key)
                if isinstance(value, str):
                    thread_ids.update(re.findall(r'\bomt_[A-Za-z0-9]+\b', value))

            for text_value in self._iter_message_text_values(message_data):
                message_ids.update(re.findall(r'\bom_[A-Za-z0-9]+\b', text_value))
                chat_ids.update(re.findall(r'\boc_[A-Za-z0-9]+\b', text_value))
                thread_ids.update(re.findall(r'\bomt_[A-Za-z0-9]+\b', text_value))

        return message_ids, chat_ids, thread_ids

    def _is_feishu_reconcile_session(self, records: List[Dict[str, Any]], session_context: Dict[str, Any],
                                     message_ids: Set[str], chat_ids: Set[str], thread_ids: Set[str]) -> bool:
        """判断一批记录是否来自飞书会话。"""
        channel = session_context.get('lastChannel') or session_context.get('deliveryContext', {}).get('channel')
        if channel == 'feishu':
            return True
        if message_ids or chat_ids or thread_ids:
            return True

        for record in records:
            message_data = record.get('message', {}) if isinstance(record.get('message'), dict) else {}
            for text_value in self._iter_message_text_values(message_data):
                if 'Conversation info (untrusted metadata)' in text_value or 'Sender (untrusted metadata)' in text_value:
                    return True
                if 'feishu:' in text_value:
                    return True

        return False

    def _iter_message_text_values(self, message_data: Dict[str, Any]) -> List[str]:
        """收集消息中可搜索的文本值。"""
        values: List[str] = []
        for item in message_data.get('content', []):
            if not isinstance(item, dict):
                continue
            text = item.get('text')
            if isinstance(text, str) and text:
                values.append(text)
        body_payload = message_data.get('body') if isinstance(message_data.get('body'), dict) else {}
        body_content = body_payload.get('content')
        if isinstance(body_content, str) and body_content:
            values.append(body_content)
        return values

    def _resolve_feishu_credentials(self) -> Optional[Dict[str, str]]:
        """从 openclaw.json + 环境变量解析飞书 appId/appSecret。"""
        config_path = Path("C:/Users/RickQ/.openclaw/openclaw.json")
        if not config_path.exists():
            return None

        try:
            config = json.loads(config_path.read_text(encoding='utf-8'))
        except json.JSONDecodeError:
            return None

        feishu_cfg = config.get('channels', {}).get('feishu', {})
        app_id = self._resolve_env_reference(feishu_cfg.get('appId'))
        app_secret = self._resolve_env_reference(feishu_cfg.get('appSecret'))
        if not app_id or not app_secret:
            return None

        return {
            'app_id': app_id,
            'app_secret': app_secret,
        }

    def _resolve_env_reference(self, value: Any) -> Optional[str]:
        """解析 ${ENV_NAME} 形式的配置引用。"""
        if value in (None, ''):
            return None
        if not isinstance(value, str):
            return str(value)

        match = re.fullmatch(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}', value.strip())
        if match:
            return os.environ.get(match.group(1))
        return value

    def _list_feishu_messages(self, app_id: str, app_secret: str,
                              container_id_type: str, container_id: str,
                              start_time: int, end_time: int) -> List[Dict[str, Any]]:
        """调用飞书历史消息列表接口。"""
        tenant_access_token = self._fetch_feishu_tenant_access_token(app_id, app_secret)
        items: List[Dict[str, Any]] = []
        page_token: Optional[str] = None

        while True:
            query = {
                'container_id_type': container_id_type,
                'container_id': container_id,
                'start_time': str(start_time),
                'end_time': str(end_time),
                'sort_type': 'ByCreateTimeAsc',
                'page_size': '50',
            }
            if page_token:
                query['page_token'] = page_token

            request_url = f"https://open.feishu.cn/open-apis/im/v1/messages?{urllib_parse.urlencode(query)}"
            request = urllib_request.Request(
                request_url,
                headers={
                    'Authorization': f'Bearer {tenant_access_token}',
                    'Content-Type': 'application/json; charset=utf-8',
                },
                method='GET',
            )

            try:
                with urllib_request.urlopen(request, timeout=20) as response:
                    payload = json.loads(response.read().decode('utf-8'))
            except urllib_error.HTTPError as exc:
                response_text = exc.read().decode('utf-8', errors='replace')
                raise RuntimeError(f'Feishu history HTTP {exc.code}: {response_text}') from exc

            if payload.get('code') != 0:
                raise RuntimeError(f"Feishu history API error {payload.get('code')}: {payload.get('msg')}")

            data = payload.get('data', {}) if isinstance(payload.get('data'), dict) else {}
            items.extend(data.get('items', []))
            if not data.get('has_more'):
                break
            page_token = data.get('page_token')
            if not page_token:
                break

        return items

    def _fetch_feishu_tenant_access_token(self, app_id: str, app_secret: str) -> str:
        """获取飞书 tenant_access_token。"""
        request = urllib_request.Request(
            'https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal',
            data=json.dumps({
                'app_id': app_id,
                'app_secret': app_secret,
            }).encode('utf-8'),
            headers={
                'Content-Type': 'application/json; charset=utf-8',
            },
            method='POST',
        )

        try:
            with urllib_request.urlopen(request, timeout=20) as response:
                payload = json.loads(response.read().decode('utf-8'))
        except urllib_error.HTTPError as exc:
            response_text = exc.read().decode('utf-8', errors='replace')
            raise RuntimeError(f'Feishu token HTTP {exc.code}: {response_text}') from exc

        if payload.get('code') != 0:
            raise RuntimeError(f"Feishu token API error {payload.get('code')}: {payload.get('msg')}")

        token = payload.get('tenant_access_token')
        if not token:
            raise RuntimeError('Feishu token API returned no tenant_access_token')
        return token
    
    def _sync_records_to_md(self, date_str: str, records: List[Dict],
                            session_context: Optional[Dict[str, Any]] = None):
        """将记录同步到 Markdown 文件"""
        conversation_file = self.sessions_dir / f"{date_str}-conversation.md"
        
        # 确保文件头部
        if not conversation_file.exists() or conversation_file.stat().st_size == 0:
            date_display = datetime.strptime(date_str, "%Y-%m-%d").strftime("%Y年%m月%d日")
            header = f"""# 对话记录
**日期**: {date_display}
**记录模式**: ✅ Logger Agent 同步
**同步时间**: {datetime.now().strftime("%Y-%m-%d %H:%M:%S")}

---

"""
            conversation_file.write_text(header, encoding='utf-8')
        
        entries = self._build_sync_entries(records, session_context or {})

        with open(conversation_file, 'a', encoding='utf-8') as f:
            for entry in entries:
                metadata_block = self.rt_logger.format_metadata_block(entry['metadata'], fallback_timestamp=entry['time'])
                f.write(f"**{entry['role_name']}** {entry['time']}\n{metadata_block}{entry['content']}\n\n---\n\n")

    def _build_sync_entries(self, records: List[Dict], session_context: Dict[str, Any]) -> List[Dict[str, Any]]:
        """构建同步条目，并把发送结果 metadata 合并回 assistant 正文。"""
        entries: List[Dict[str, Any]] = []

        for record in records:
            message_data = record.get('message', {})
            role = message_data.get('role', 'unknown')
            content, metadata = self._extract_content_and_metadata(record, message_data, session_context)
            timestamp = record.get('timestamp', '')
            time_str = self._extract_time_str(timestamp)
            role_name = "Rick" if role == "user" else "CC" if role == "assistant" else role

            entries.append({
                'record': record,
                'message_data': message_data,
                'role': role,
                'role_name': role_name,
                'time': time_str,
                'content': content,
                'metadata': metadata,
            })

        for index, entry in enumerate(entries):
            message_data = entry['message_data']
            if entry['role'] != 'toolResult' or message_data.get('toolName') != 'message':
                continue

            target_index = self._find_assistant_entry_for_outbound(entries, index)
            if target_index is None:
                continue

            merged = self._merge_metadata(entries[target_index]['metadata'], {
                key: value
                for key, value in entry['metadata'].items()
                if value not in (None, '', 'tool-result')
            })
            merged['direction'] = 'outbound'
            entries[target_index]['metadata'] = self.rt_logger.normalize_metadata(merged)

        return entries

    def _extract_time_str(self, timestamp: str) -> str:
        """提取 HH:MM 时间。"""
        if timestamp:
            match = re.search(r'(\d{2}:\d{2}:\d{2})', timestamp)
            if match:
                return match.group(1)[:5]
        return datetime.now().strftime("%H:%M")

    def _find_assistant_entry_for_outbound(self, entries: List[Dict[str, Any]], tool_result_index: int) -> Optional[int]:
        """为发送成功的 message toolResult 找到对应的 assistant 正文条目。"""
        for candidate in range(tool_result_index - 1, max(-1, tool_result_index - 4), -1):
            entry = entries[candidate]
            if entry['role'] != 'assistant':
                continue
            if entry['content'].strip() == 'NO_REPLY':
                continue
            if '[工具调用:' in entry['content'] and not entry['content'].strip().startswith('{'):
                continue
            return candidate

        for candidate in range(tool_result_index + 1, min(len(entries), tool_result_index + 3)):
            entry = entries[candidate]
            if entry['role'] == 'assistant' and entry['content'].strip() != 'NO_REPLY':
                return candidate

        return None
    
    def _extract_content_and_metadata(self, record: Dict[str, Any], message_data: Dict[str, Any],
                                      session_context: Dict[str, Any]) -> (str, Dict[str, Any]):
        """从消息数据中提取正文并归一化飞书元数据。"""
        content_parts = []
        metadata = self._base_metadata(record, message_data, session_context)
        
        if 'content' not in message_data:
            return "[无内容]", metadata

        body_payload = message_data.get('body') if isinstance(message_data.get('body'), dict) else {}
        if isinstance(body_payload.get('content'), str) and body_payload.get('content').strip():
            metadata = self._merge_metadata(metadata, {
                'raw_body_content': body_payload.get('content').strip(),
                'raw_body_length': len(body_payload.get('content').strip()),
                'metadata_sources': ['message_body'],
            })
        
        for item in message_data['content']:
            item_type = item.get('type', '')
            
            if item_type == 'text':
                text = item.get('text', '')
                if text:
                    if message_data.get('role') == 'toolResult':
                        cleaned_text, extracted = self._extract_tool_result_metadata(text, message_data)
                    else:
                        cleaned_text, extracted = self._extract_text_metadata(text)
                    metadata = self._merge_metadata(metadata, extracted)
                    if cleaned_text:
                        content_parts.append(cleaned_text)
            
            elif item_type == 'toolCall':
                tool_name = item.get('name', 'unknown')
                content_parts.append(f"[工具调用: `{tool_name}`]")
            
            elif item_type == 'toolResult':
                tool_name = item.get('toolName', 'unknown')
                is_error = item.get('isError', False)
                status = "❌ 错误" if is_error else "✅ 成功"
                content_parts.append(f"[工具结果: `{tool_name}`] {status}")

        normalized = self.rt_logger.normalize_metadata(metadata)
        return "\n".join(content_parts) if content_parts else "[无内容]", normalized

    def _merge_metadata(self, base: Dict[str, Any], extra: Dict[str, Any]) -> Dict[str, Any]:
        """合并 metadata，并保留来源列表。"""
        merged = dict(base)
        sources: List[str] = []

        for candidate in (base.get('metadata_sources'), extra.get('metadata_sources')):
            if isinstance(candidate, list):
                sources.extend(str(item) for item in candidate if item not in (None, ''))
            elif candidate not in (None, ''):
                sources.append(str(candidate))

        for key, value in extra.items():
            if key == 'metadata_sources':
                continue
            if value not in (None, ''):
                merged[key] = value

        if sources:
            merged['metadata_sources'] = list(dict.fromkeys(sources))

        return merged

    def _base_metadata(self, record: Dict[str, Any], message_data: Dict[str, Any],
                       session_context: Dict[str, Any]) -> Dict[str, Any]:
        """构建会话级默认 metadata。"""
        metadata: Dict[str, Any] = {}

        delivery_context = session_context.get('deliveryContext', {})
        origin = session_context.get('origin', {})

        metadata['channel'] = origin.get('provider') or origin.get('surface') or delivery_context.get('channel') or session_context.get('channel')
        metadata['chat_type'] = origin.get('chatType') or session_context.get('chatType')
        metadata['account_id'] = origin.get('accountId') or delivery_context.get('accountId')
        metadata['session_id'] = session_context.get('sessionId') or record.get('sessionId')
        metadata['from'] = origin.get('from')
        metadata['to'] = origin.get('to') or delivery_context.get('to')
        metadata['chat_id'] = session_context.get('chatId') or delivery_context.get('chatId') or delivery_context.get('to')
        metadata['create_time'] = message_data.get('createTime') or message_data.get('create_time')
        metadata['update_time'] = message_data.get('updateTime') or message_data.get('update_time')
        metadata['logged_at'] = record.get('timestamp') or message_data.get('timestamp')
        metadata['msg_type'] = message_data.get('msgType') or message_data.get('msg_type')
        metadata['root_id'] = message_data.get('rootId') or message_data.get('root_id')
        metadata['parent_id'] = message_data.get('parentId') or message_data.get('parent_id')
        metadata['thread_id'] = message_data.get('threadId') or message_data.get('thread_id')
        metadata['upper_message_id'] = message_data.get('upperMessageId') or message_data.get('upper_message_id')
        metadata['deleted'] = message_data.get('deleted')
        metadata['updated'] = message_data.get('updated')
        metadata['metadata_sources'] = ['session_context']

        role = message_data.get('role', '')
        if role == 'user':
            metadata['direction'] = 'inbound'
        elif role == 'assistant':
            metadata['direction'] = 'outbound'
        elif role == 'toolResult':
            metadata['direction'] = 'tool-result'
        else:
            metadata['direction'] = role or 'unknown'

        sender_label = message_data.get('senderLabel') or session_context.get('displayName')
        if sender_label:
            metadata['sender'] = sender_label
            metadata['sender_id'] = sender_label

        sender_obj = message_data.get('sender') if isinstance(message_data.get('sender'), dict) else {}
        if sender_obj:
            metadata.update({
                'sender_id': sender_obj.get('id') or metadata.get('sender_id'),
                'sender_id_type': sender_obj.get('id_type'),
                'sender_type': sender_obj.get('sender_type'),
                'sender_tenant_key': sender_obj.get('tenant_key'),
            })

        delivery_metadata = message_data.get('deliveryMetadata')
        if isinstance(delivery_metadata, dict):
            metadata = self._merge_metadata(metadata, {
                **delivery_metadata,
                'metadata_sources': ['delivery_metadata'],
            })

        return metadata

    def _extract_text_metadata(self, text: str) -> (str, Dict[str, Any]):
        """从 OpenClaw 注入的正文前言中剥离 metadata。"""
        metadata: Dict[str, Any] = {}
        cleaned = text

        block_patterns = [
            ('conversation', r'Conversation info \(untrusted metadata\):\s*```json\s*(\{.*?\})\s*```'),
            ('sender', r'Sender \(untrusted metadata\):\s*```json\s*(\{.*?\})\s*```'),
            ('replied', r'Replied message \(untrusted, for context\):\s*```json\s*(\{.*?\})\s*```'),
        ]

        for block_type, pattern in block_patterns:
            match = re.search(pattern, cleaned, re.DOTALL)
            if not match:
                continue
            try:
                payload = json.loads(match.group(1))
            except json.JSONDecodeError:
                payload = {}

            if block_type == 'conversation':
                body_payload = payload.get('body') if isinstance(payload.get('body'), dict) else {}
                raw_body_content = body_payload.get('content') if isinstance(body_payload.get('content'), str) else None
                metadata.update({
                    'metadata_sources': ['conversation_block'],
                    'message_id': payload.get('message_id'),
                    'reply_to_id': payload.get('reply_to_id'),
                    'root_id': payload.get('root_id') or payload.get('rootId'),
                    'parent_id': payload.get('parent_id') or payload.get('parentId'),
                    'thread_id': payload.get('thread_id') or payload.get('threadId'),
                    'upper_message_id': payload.get('upper_message_id') or payload.get('upperMessageId'),
                    'chat_id': payload.get('chat_id') or payload.get('chatId'),
                    'msg_type': payload.get('msg_type') or payload.get('msgType') or payload.get('message_type'),
                    'sender': payload.get('sender'),
                    'sender_id': payload.get('sender_id'),
                    'sender_id_type': payload.get('sender_id_type') or payload.get('senderIdType') or payload.get('id_type'),
                    'sender_type': payload.get('sender_type') or payload.get('senderType'),
                    'sender_tenant_key': payload.get('sender_tenant_key') or payload.get('tenant_key'),
                    'create_time': payload.get('create_time') or payload.get('createTime') or payload.get('timestamp'),
                    'update_time': payload.get('update_time') or payload.get('updateTime'),
                    'deleted': payload.get('deleted'),
                    'updated': payload.get('updated'),
                    'mentions': payload.get('mentions'),
                    'raw_body_content': raw_body_content,
                    'raw_body_length': len(raw_body_content) if raw_body_content else None,
                })
            elif block_type == 'sender':
                metadata.update({
                    'metadata_sources': ['sender_block'],
                    'sender': payload.get('name') or payload.get('label') or payload.get('id'),
                    'sender_id': payload.get('id') or payload.get('label'),
                    'sender_id_type': payload.get('id_type'),
                    'sender_type': payload.get('sender_type'),
                    'sender_tenant_key': payload.get('tenant_key'),
                })
            elif block_type == 'replied':
                metadata.update({
                    'metadata_sources': ['replied_context'],
                    'reply_to_id': payload.get('message_id') or payload.get('reply_to_id') or payload.get('parent_id'),
                    'root_id': payload.get('root_id') or payload.get('rootId') or metadata.get('root_id'),
                    'parent_id': payload.get('parent_id') or payload.get('parentId') or metadata.get('parent_id'),
                    'thread_id': payload.get('thread_id') or payload.get('threadId') or metadata.get('thread_id'),
                })

            cleaned = cleaned.replace(match.group(0), '').strip()

        prefix_match = re.match(
            r'^\[message_id:\s*(?P<message_id>[^\]]+)\]\s*\n?(?P<sender>[^:\n]+):\s*(?P<body>.*)$',
            cleaned,
            re.DOTALL,
        )
        if prefix_match:
            metadata.setdefault('message_id', prefix_match.group('message_id').strip())
            sender_value = prefix_match.group('sender').strip()
            metadata.setdefault('sender', sender_value)
            metadata.setdefault('sender_id', sender_value)
            metadata.setdefault('metadata_sources', ['legacy_prefix'])
            cleaned = prefix_match.group('body').strip()

        cleaned = cleaned.strip()
        return cleaned or '[无内容]', {k: v for k, v in metadata.items() if v not in (None, '')}

    def _extract_tool_result_metadata(self, text: str, message_data: Dict[str, Any]) -> (str, Dict[str, Any]):
        """从 message 工具结果里提取发送侧飞书 metadata。"""
        metadata: Dict[str, Any] = {}
        cleaned = text.strip()

        try:
            payload = json.loads(cleaned)
        except json.JSONDecodeError:
            return cleaned or '[无内容]', metadata

        if isinstance(payload, dict):
            result = payload.get('result', {}) if isinstance(payload.get('result'), dict) else {}
            body_payload = payload.get('body') if isinstance(payload.get('body'), dict) else {}
            raw_body_content = body_payload.get('content') if isinstance(body_payload.get('content'), str) else None
            metadata.update({
                'metadata_sources': ['tool_result'],
                'channel': result.get('channel') or payload.get('channel'),
                'message_id': result.get('messageId') or payload.get('messageId'),
                'reply_to_id': result.get('replyToId') or payload.get('replyToId'),
                'chat_id': result.get('chatId') or payload.get('chatId') or payload.get('to'),
                'msg_type': result.get('msgType') or payload.get('msgType') or 'text',
                'to': payload.get('to'),
                'direction': 'outbound' if message_data.get('toolName') == 'message' else 'tool-result',
                'sender': 'bot:main' if message_data.get('toolName') == 'message' else None,
                'sender_type': 'app' if message_data.get('toolName') == 'message' else None,
                'logged_at': payload.get('timestamp') or payload.get('loggedAt'),
                'raw_body_content': raw_body_content,
                'raw_body_length': len(raw_body_content) if raw_body_content else None,
            })

        return cleaned or '[无内容]', {k: v for k, v in metadata.items() if v not in (None, '')}
    
    # ============ 每日摘要功能 ============
    
    def generate_daily_summary(self, date_str: Optional[str] = None) -> Optional[Path]:
        """
        生成每日摘要
        
        Args:
            date_str: 日期 (YYYY-MM-DD)，默认今天
        
        Returns:
            摘要文件路径
        """
        if date_str is None:
            date_str = datetime.now().strftime("%Y-%m-%d")
        
        conversation_file = self.sessions_dir / f"{date_str}-conversation.md"
        summary_file = self.memory_dir / f"{date_str}.md"
        
        if not conversation_file.exists():
            print(f"[WARN] 对话文件不存在: {conversation_file}")
            return None
        
        # 读取并分析
        content = conversation_file.read_text(encoding='utf-8')
        
        # 统计
        user_count = content.count("**Rick**")
        assistant_count = content.count("**CC**")
        tool_count = content.count("[工具")
        
        # 提取话题
        topics = self._extract_topics(content)
        
        # 提取决策和行动项
        decisions = self._extract_decisions(content)
        
        # 生成摘要
        summary = f"""# {date_str} 日志

## 对话统计
- **用户消息**: {user_count} 条
- **助手回复**: {assistant_count} 条
- **工具调用**: {tool_count} 次

## 话题概览
{chr(10).join(['- ' + t for t in topics[:10]]) if topics else '- （待整理）'}

## 重要决策与行动项
{chr(10).join(['- [ ] ' + d for d in decisions[:5]]) if decisions else '- [ ] 待从对话中识别并补充'}

## 详细记录
- 完整对话: `sessions/{date_str}-conversation.md`

---

*生成时间: {datetime.now().strftime("%Y-%m-%d %H:%M:%S")}*
*生成者: Logger Agent*
"""
        
        summary_file.write_text(summary, encoding='utf-8')
        
        # 更新状态
        if date_str not in self.state['daily_summaries']:
            self.state['daily_summaries'].append(date_str)
        self.save_state()
        
        print(f"[OK] 每日摘要已生成: {summary_file}")
        return summary_file
    
    def _extract_topics(self, content: str) -> List[str]:
        """提取话题"""
        topics = []
        
        # 查找加粗文本
        bold_matches = re.findall(r'\*\*([^*]+)\*\*', content)
        for match in bold_matches:
            if match not in ['Rick', 'CC', 'System'] and len(match) > 5:
                topics.append(match)
        
        # 查找标题
        header_matches = re.findall(r'^##?\s+(.+)$', content, re.MULTILINE)
        for match in header_matches:
            if len(match) > 3:
                topics.append(match.strip())
        
        # 去重
        seen = set()
        unique_topics = []
        for t in topics:
            if t not in seen and len(unique_topics) < 15:
                seen.add(t)
                unique_topics.append(t)
        
        return unique_topics
    
    def _extract_decisions(self, content: str) -> List[str]:
        """提取决策和行动项"""
        decisions = []
        
        # 查找决策关键词
        decision_patterns = [
            r'(?:决定|决策|确定|约定|同意|批准)[：:]\s*(.+)',
            r'(?:TODO|FIXME|Action|Decision)[：:]\s*(.+)',
            r'(?:下一步|待办|行动项)[：:]\s*(.+)'
        ]
        
        for pattern in decision_patterns:
            matches = re.findall(pattern, content, re.IGNORECASE)
            decisions.extend(matches)
        
        return decisions[:10]
    
    # ============ 归档功能 ============
    
    def archive_old_sessions(self, days: int = 30) -> Dict[str, Any]:
        """
        归档过期会话
        
        Args:
            days: 超过多少天的会话需要归档
        
        Returns:
            归档结果
        """
        cutoff_date = datetime.now() - timedelta(days=days)
        archived = []
        
        # 检查 sessions 目录
        for md_file in self.sessions_dir.glob("*-conversation.md"):
            # 提取日期
            match = re.match(r'(\d{4}-\d{2}-\d{2})-conversation\.md', md_file.name)
            if match:
                file_date = datetime.strptime(match.group(1), "%Y-%m-%d")
                if file_date < cutoff_date:
                    # 归档
                    target = self.archive_dir / "sessions" / md_file.name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    md_file.rename(target)
                    archived.append(md_file.name)
        
        # 更新状态
        self.state['archived_dates'].extend(archived)
        self.save_state()
        
        return {
            'archived_files': archived,
            'archive_count': len(archived),
            'archive_dir': str(self.archive_dir / "sessions")
        }
    
    # ============ 主入口 ============
    
    def run_sync_task(self):
        """运行同步任务（用于 cron）"""
        print(f"\n[Logger Agent] 开始同步任务 - {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        
        # 同步今天
        today = datetime.now().strftime("%Y-%m-%d")
        result = self.sync_from_main_sessions(today)
        
        print(f"[OK] 同步完成: {result['total_records']} 条记录")
        print(f"  文件: {result['conversation_file']}")
        
        return result

    def run_rebuild_task(self, date_str: Optional[str] = None):
        """运行重建任务。"""
        target_date = date_str or datetime.now().strftime("%Y-%m-%d")
        print(f"\n[Logger Agent] 开始重建任务 - {target_date} - {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")

        result = self.rebuild_from_main_sessions(target_date)

        print(f"[OK] 重建完成: {result['total_records']} 条记录")
        print(f"  文件: {result['conversation_file']}")

        return result
    
    def run_daily_summary_task(self):
        """运行每日摘要任务（用于 cron）"""
        print(f"\n[Logger Agent] 开始生成每日摘要 - {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        
        # 生成今天
        today = datetime.now().strftime("%Y-%m-%d")
        summary_file = self.generate_daily_summary(today)
        
        if summary_file:
            print(f"[OK] 摘要已生成: {summary_file}")
        
        return summary_file
    
    def run_archive_task(self):
        """运行归档任务"""
        print(f"\n[Logger Agent] 开始归档任务 - {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        
        result = self.archive_old_sessions(days=30)
        
        print(f"[OK] 归档完成: {result['archive_count']} 个文件")
        
        return result


# ============ 命令行入口 ============

if __name__ == "__main__":
    import argparse
    
    parser = argparse.ArgumentParser(description="Logger Agent - 会话记录与总结")
    parser.add_argument("--sync", "-s", action="store_true", help="同步会话")
    parser.add_argument("--sync-date", "-d", help="同步指定日期 (YYYY-MM-DD)")
    parser.add_argument("--summary", action="store_true", help="生成每日摘要")
    parser.add_argument("--summary-date", help="生成指定日期的摘要")
    parser.add_argument("--archive", "-a", action="store_true", help="归档旧会话")
    parser.add_argument("--rebuild", action="store_true", help="重建指定日期的对话文件")
    parser.add_argument("--rebuild-date", help="重建指定日期 (YYYY-MM-DD)")
    parser.add_argument("--reconcile-feishu", action="store_true", help="对比飞书远端历史与本地归档差异")
    parser.add_argument("--reconcile-date", help="对比指定日期 (YYYY-MM-DD)")
    parser.add_argument("--reconcile-container-id", action="append", help="手动指定飞书容器 ID，可重复传入")
    parser.add_argument("--reconcile-feishu-write", action="store_true", help="把飞书远端缺失消息写入 stage 文件")
    parser.add_argument("--reconcile-feishu-merge", action="store_true", help="把 stage 文件合并进当天对话归档")
    parser.add_argument("--all", action="store_true", help="执行所有任务")
    
    args = parser.parse_args()
    
    agent = LoggerAgent()
    
    if args.sync:
        result = agent.sync_from_main_sessions(args.sync_date)
        print(json.dumps(result, indent=2, ensure_ascii=False))

    elif args.rebuild:
        result = agent.rebuild_from_main_sessions(args.rebuild_date)
        print(json.dumps(result, indent=2, ensure_ascii=False))

    elif args.reconcile_feishu:
        result = agent.reconcile_feishu_history(args.reconcile_date, args.reconcile_container_id)
        print(json.dumps(result, indent=2, ensure_ascii=False))

    elif args.reconcile_feishu_write:
        result = agent.reconcile_feishu_history_to_stage(args.reconcile_date, args.reconcile_container_id)
        print(json.dumps(result, indent=2, ensure_ascii=False))

    elif args.reconcile_feishu_merge:
        result = agent.merge_reconcile_stage(args.reconcile_date)
        print(json.dumps(result, indent=2, ensure_ascii=False))
    
    elif args.summary:
        summary_file = agent.generate_daily_summary(args.summary_date)
        if summary_file:
            print(f"[OK] 摘要已生成: {summary_file}")
    
    elif args.archive:
        result = agent.run_archive_task()
        print(json.dumps(result, indent=2, ensure_ascii=False))
    
    elif args.all:
        agent.run_sync_task()
        agent.run_daily_summary_task()
        agent.run_archive_task()
    
    else:
        print("Logger Agent - 会话记录与总结系统")
        print("\n使用方式:")
        print("  --sync, -s          同步今天的会话")
        print("  --sync-date DATE    同步指定日期")
        print("  --rebuild           重建指定日期的对话文件")
        print("  --rebuild-date DATE 重建指定日期")
        print("  --reconcile-feishu  对比飞书远端历史与本地归档")
        print("  --reconcile-date DATE 对比指定日期")
        print("  --reconcile-container-id ID 手动指定飞书容器 ID")
        print("  --reconcile-feishu-write 把飞书远端缺失消息写入 stage 文件")
        print("  --reconcile-feishu-merge 把 stage 文件合并进当天对话归档")
        print("  --summary           生成今天的摘要")
        print("  --summary-date DATE 生成指定日期的摘要")
        print("  --archive, -a       归档旧会话")
        print("  --all               执行所有任务")
