"""
Django Management Command: S3 Download

Downloads a file from object storage (Wasabi/OCI/S3/MinIO)

Usage:
    python manage.py s3_download --path agent-uploads/123/screenshot.png --dest /tmp/
    python manage.py s3_download --agent 123 --filename screenshot.png

Installation:
    Copy this file to: api/tacticalrmm/core/management/commands/s3_download.py
"""

from django.core.management.base import BaseCommand, CommandError
import subprocess
import os


class Command(BaseCommand):
    help = 'Download file from object storage'

    def add_arguments(self, parser):
        parser.add_argument(
            '--bucket',
            type=str,
            default='pota4-transfers',
            help='Bucket name (default: pota4-transfers)'
        )
        parser.add_argument(
            '--path',
            type=str,
            help='Remote path in bucket (e.g., agent-uploads/123/file.png)'
        )
        parser.add_argument(
            '--agent',
            type=str,
            help='Agent ID (looks in agent-uploads/{agent}/)'
        )
        parser.add_argument(
            '--filename',
            type=str,
            help='Filename to download (used with --agent)'
        )
        parser.add_argument(
            '--dest',
            type=str,
            default='/tmp',
            help='Local destination directory (default: /tmp)'
        )

    def handle(self, *args, **options):
        bucket = options['bucket']
        dest_dir = options['dest']

        # Determine remote path
        if options['agent'] and options['filename']:
            agent_id = options['agent']
            filename = options['filename']
            remote_path = f"agent-uploads/{agent_id}/{filename}"
        elif options['path']:
            remote_path = options['path']
        else:
            raise CommandError('Either --path or (--agent and --filename) must be specified')

        # Create destination directory if it doesn't exist
        os.makedirs(dest_dir, exist_ok=True)

        self.stdout.write(f'Downloading: {bucket}/{remote_path}')
        self.stdout.write(f'To: {dest_dir}/')

        # Download using rclone
        try:
            result = subprocess.run(
                [
                    'rclone',
                    'copy',
                    f'pota4-storage:{bucket}/{remote_path}',
                    dest_dir,
                    '--progress'
                ],
                capture_output=True,
                text=True,
                check=True
            )

            local_file = os.path.join(dest_dir, os.path.basename(remote_path))

            self.stdout.write(self.style.SUCCESS(
                f'✓ Download successful: {local_file}'
            ))

        except subprocess.CalledProcessError as e:
            raise CommandError(f'Download failed: {e.stderr}')

        except FileNotFoundError:
            raise CommandError('rclone not found. Please install rclone.')
