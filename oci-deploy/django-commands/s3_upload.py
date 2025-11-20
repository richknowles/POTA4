"""
Django Management Command: S3 Upload

Uploads a file to object storage (Wasabi/OCI/S3/MinIO)

Usage:
    python manage.py s3_upload --file /path/to/file --bucket transfers --path agent/123/file.exe
    python manage.py s3_upload --file /path/to/file --agent 123 --filename tool.exe

Installation:
    Copy this file to: api/tacticalrmm/core/management/commands/s3_upload.py
"""

from django.core.management.base import BaseCommand, CommandError
import subprocess
import os
from pathlib import Path


class Command(BaseCommand):
    help = 'Upload file to object storage'

    def add_arguments(self, parser):
        parser.add_argument(
            '--file',
            type=str,
            required=True,
            help='Local file path to upload'
        )
        parser.add_argument(
            '--bucket',
            type=str,
            default='pota4-transfers',
            help='Bucket name (default: pota4-transfers)'
        )
        parser.add_argument(
            '--path',
            type=str,
            help='Remote path in bucket (e.g., agent/123/file.exe)'
        )
        parser.add_argument(
            '--agent',
            type=str,
            help='Agent ID (auto-constructs path: tech-staging/{agent}/{filename})'
        )
        parser.add_argument(
            '--filename',
            type=str,
            help='Remote filename (used with --agent)'
        )

    def handle(self, *args, **options):
        local_file = options['file']
        bucket = options['bucket']

        # Validate file exists
        if not os.path.isfile(local_file):
            raise CommandError(f'File not found: {local_file}')

        # Determine remote path
        if options['agent']:
            agent_id = options['agent']
            filename = options['filename'] or os.path.basename(local_file)
            remote_path = f"tech-staging/{agent_id}/{filename}"
        elif options['path']:
            remote_path = options['path']
        else:
            raise CommandError('Either --path or --agent must be specified')

        self.stdout.write(f'Uploading: {local_file}')
        self.stdout.write(f'To: {bucket}/{remote_path}')

        # Upload using rclone
        try:
            result = subprocess.run(
                [
                    'rclone',
                    'copy',
                    local_file,
                    f'pota4-storage:{bucket}/{os.path.dirname(remote_path)}',
                    '--progress'
                ],
                capture_output=True,
                text=True,
                check=True
            )

            self.stdout.write(self.style.SUCCESS(
                f'✓ Upload successful: {bucket}/{remote_path}'
            ))

        except subprocess.CalledProcessError as e:
            raise CommandError(f'Upload failed: {e.stderr}')

        except FileNotFoundError:
            raise CommandError('rclone not found. Please install rclone.')
